[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,

    [Parameter(Mandatory)]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory)]
    [string]$ExpectedManifestSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-WinAirPlaySigningHost
$sourceDirectory = (Resolve-Path -LiteralPath $PackageDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    throw "Test-signing source is not a directory: $sourceDirectory"
}
$thumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -cnotmatch '^[0-9A-F]{40}$') {
    throw "Certificate thumbprint must contain exactly 40 hexadecimal characters: '$thumbprint'"
}
$expectedManifestHash = $ExpectedManifestSha256.Replace(' ', '').ToUpperInvariant()
if ($expectedManifestHash -cnotmatch '^[0-9A-F]{64}$') {
    throw "Expected unsigned manifest hash must contain exactly 64 hexadecimal characters: '$expectedManifestHash'"
}
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

if (-not $PSCmdlet.ShouldProcess(
        $sourceDirectory,
        "Snapshot, validate the pinned unsigned manifest $expectedManifestHash, and test-sign the exact WinAirPlayAudio package with $thumbprint")) {
    return
}

$installerMutex = Enter-WinAirPlayInstallerMutex
$snapshot = $null
$toolSnapshot = $null
$outputDirectory = $null
$outputOwned = $false
$outputRootOwned = $false
try {
    # Never sign in caller-controlled storage. The protected snapshot closes
    # package-swap races. The operator-supplied preimage hash anchors provenance.
    $snapshot = New-WinAirPlayPackageSnapshot -SourceDirectory $sourceDirectory
    $actualManifestHash = (Get-FileHash `
            -LiteralPath (Join-Path $snapshot 'package-manifest.json') `
            -Algorithm SHA256).Hash
    if ($actualManifestHash -cne $expectedManifestHash) {
        throw "Unsigned package manifest hash '$actualManifestHash' does not match the explicitly trusted preimage '$expectedManifestHash'."
    }
    $package = Resolve-WinAirPlayPackage -PackageDirectory $snapshot
    $manifest = Get-Content -LiteralPath $package.Manifest -Raw |
        ConvertFrom-Json -ErrorAction Stop

    $expectedFiles = @(Get-WinAirPlayPackageFileNames)
    $actualFiles = @(Get-ChildItem -LiteralPath $snapshot -Force -File |
            ForEach-Object Name)
    $unexpected = @($actualFiles | Where-Object { $_ -notin $expectedFiles })
    $missing = @($expectedFiles | Where-Object { $_ -notin $actualFiles })
    if ($unexpected.Count -ne 0 -or $missing.Count -ne 0) {
        throw "Test signing requires the exact package file set. Missing=[$($missing -join ', ')]; unexpected=[$($unexpected -join ', ')]."
    }

    $userExecutableNames = @($expectedFiles |
            Where-Object { [IO.Path]::GetExtension($_) -ieq '.exe' })
    $userExecutables = @($userExecutableNames |
            ForEach-Object { Join-Path $snapshot $_ })
    foreach ($path in @($package.Inf, $package.Sys, $package.Cat, $package.Manifest) +
        $userExecutables) {
        Assert-WinAirPlayRegularFile -Path $path
    }

    $certificatePath = "Cert:\LocalMachine\My\$thumbprint"
    $certificate = Get-Item -LiteralPath $certificatePath -ErrorAction Stop
    if (-not $certificate.HasPrivateKey) {
        throw "Certificate has no accessible private key: $thumbprint"
    }
    if ($certificate.NotAfter -le [DateTime]::Now) {
        throw "Certificate is expired: $thumbprint"
    }
    if ($certificate.FriendlyName -cne 'WinAirPlayAudio driver test signing' -or
        $certificate.Subject -cne $certificate.Issuer) {
        throw 'Test signing accepts only the dedicated self-signed certificate created by New-TestCertificate.ps1.'
    }
    $codeSigningOid = '1.3.6.1.5.5.7.3.3'
    if (-not ($certificate.Extensions |
            Where-Object {
                $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
            } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            Where-Object { $_.Value -eq $codeSigningOid })) {
        throw "Certificate does not contain the Code Signing EKU: $thumbprint"
    }
    foreach ($trustStore in @('Root', 'TrustedPublisher')) {
        $trustedCertificate = Get-Item `
            -LiteralPath "Cert:\LocalMachine\$trustStore\$thumbprint" `
            -ErrorAction SilentlyContinue
        if (-not $trustedCertificate -or
            $trustedCertificate.FriendlyName -cne 'WinAirPlayAudio driver test signing') {
            throw "Dedicated test certificate is not installed in LocalMachine\${trustStore}: $thumbprint"
        }
    }

    # Pinned tools and every adjacent runtime file are copied into a protected
    # directory and authenticated as exact inventories before elevation executes
    # any of them. This closes EXE, DLL, and manifest replacement races.
    $toolSnapshot = New-WinAirPlaySigningToolSnapshot
    foreach ($executable in $userExecutables) {
        Invoke-WinAirPlayAuthenticatedTool `
            -FilePath $toolSnapshot.SignToolPath `
            -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
            -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
            -ArgumentList @(
                'sign', '/v', '/fd', 'SHA256', '/sha1', $thumbprint,
                '/s', 'My', '/sm', $executable) |
            ForEach-Object { Write-Host $_ }
    }

    # The embedded SYS signature changes its hash, so Inf2Cat must run after it.
    Invoke-WinAirPlayAuthenticatedTool `
        -FilePath $toolSnapshot.SignToolPath `
        -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
        -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
        -ArgumentList @(
            'sign', '/v', '/fd', 'SHA256', '/sha1', $thumbprint,
            '/s', 'My', '/sm', $package.Sys) |
        ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayAuthenticatedTool `
        -FilePath $toolSnapshot.Inf2CatPath `
        -WorkingDirectory $toolSnapshot.Inf2CatWorkingDirectory `
        -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
        -ArgumentList @("/driver:$snapshot", '/os:10_X64', '/verbose') |
        ForEach-Object { Write-Host $_ }
    Assert-WinAirPlayRegularFile -Path $package.Cat
    Invoke-WinAirPlayAuthenticatedTool `
        -FilePath $toolSnapshot.SignToolPath `
        -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
        -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
        -ArgumentList @(
            'sign', '/v', '/fd', 'SHA256', '/sha1', $thumbprint,
            '/s', 'My', '/sm', $package.Cat) |
        ForEach-Object { Write-Host $_ }

    # Microsoft documents /pa for self-signed test driver and catalog
    # verification. /kp is the release kernel-policy check and deliberately
    # rejects a private test root even when that root is trusted locally.
    Invoke-WinAirPlayAuthenticatedTool `
        -FilePath $toolSnapshot.SignToolPath `
        -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
        -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
        -ArgumentList @('verify', '/v', '/pa', $package.Sys) |
        ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayAuthenticatedTool `
        -FilePath $toolSnapshot.SignToolPath `
        -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
        -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
        -ArgumentList @('verify', '/v', '/pa', $package.Cat) |
        ForEach-Object { Write-Host $_ }
    foreach ($catalogMember in @($package.Inf, $package.Sys)) {
        Invoke-WinAirPlayAuthenticatedTool `
            -FilePath $toolSnapshot.SignToolPath `
            -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
            -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
            -ArgumentList @(
                'verify', '/v', '/pa', '/c', $package.Cat, $catalogMember) |
            ForEach-Object { Write-Host $_ }
    }
    foreach ($executable in $userExecutables) {
        Invoke-WinAirPlayAuthenticatedTool `
            -FilePath $toolSnapshot.SignToolPath `
            -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
            -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
            -ArgumentList @('verify', '/v', '/pa', $executable) |
            ForEach-Object { Write-Host $_ }
    }

    # Refresh the complete locked inventory only after every signature verifies.
    foreach ($entry in @($manifest.Files)) {
        $file = Join-Path $snapshot $entry.Name
        Assert-WinAirPlayRegularFile -Path $file
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        $entry.Length = (Get-Item -LiteralPath $file).Length
        $entry.Sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        $entry.SignatureStatus = $signature.Status.ToString()
        $entry.SignerThumbprint = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.Thumbprint
        }
        else {
            $null
        }
    }
    $manifest.GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    $manifest | Add-Member `
        -NotePropertyName UnsignedManifestSha256 `
        -NotePropertyValue $expectedManifestHash `
        -Force
    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $package.Manifest -Encoding UTF8
    $signedManifestHash = (Get-FileHash `
            -LiteralPath $package.Manifest `
            -Algorithm SHA256 `
            -ErrorAction Stop).Hash

    $package = Resolve-WinAirPlayPackage -PackageDirectory $snapshot
    Assert-WinAirPlayPackageSignature `
        -Package $package `
        -ExpectedCatalogSignerThumbprint $thumbprint `
        -ExpectedExecutableSignerThumbprint $thumbprint

    if (Test-Path -LiteralPath $script:WinAirPlaySignedPackageRoot) {
        Assert-WinAirPlayTrustedDirectory `
            -Path $script:WinAirPlaySignedPackageRoot `
            -RequireProtectedDacl
    }
    else {
        $outputRootOwned = $true
        New-WinAirPlaySecureDirectory `
            -Path $script:WinAirPlaySignedPackageRoot `
            -UsersReadExecute
    }
    $outputDirectory = Join-Path `
        $script:WinAirPlaySignedPackageRoot `
        ([Guid]::NewGuid().ToString('N'))
    # Mark ownership before creation so rollback covers partial ACL creation.
    $outputOwned = $true
    New-WinAirPlaySecureDirectory -Path $outputDirectory -UsersReadExecute
    foreach ($file in Get-ChildItem -LiteralPath $snapshot -Force -File) {
        Copy-Item `
            -LiteralPath $file.FullName `
            -Destination (Join-Path $outputDirectory $file.Name)
    }
    $published = Resolve-WinAirPlayPackage -PackageDirectory $outputDirectory
    Assert-WinAirPlayPackageSignature `
        -Package $published `
        -ExpectedCatalogSignerThumbprint $thumbprint `
        -ExpectedExecutableSignerThumbprint $thumbprint
    $publishedManifestHash = (Get-FileHash `
            -LiteralPath $published.Manifest `
            -Algorithm SHA256 `
            -ErrorAction Stop).Hash
    if ($publishedManifestHash -cne $signedManifestHash) {
        throw "Published signed manifest '$publishedManifestHash' does not match the protected signed preimage '$signedManifestHash'."
    }

    Write-Host "Protected test-signed package is ready: $outputDirectory"
    [pscustomobject]@{
        PackageDirectory = $outputDirectory
        SignerThumbprint = $thumbprint
        UnsignedManifestSha256 = $expectedManifestHash
        SignedManifestSha256 = $signedManifestHash
    }
}
catch {
    $signingFailure = $_
    $cleanupProblems = [Collections.Generic.List[string]]::new()
    if ($outputOwned -and $outputDirectory -and
        (Test-Path -LiteralPath $outputDirectory)) {
        try {
            Remove-WinAirPlayDirectorySafe `
                -Path $outputDirectory `
                -AllowedParent $script:WinAirPlaySignedPackageRoot `
                -AllowedLeafPattern '^[0-9a-f]{32}$'
        }
        catch {
            $cleanupProblems.Add($_.Exception.Message)
        }
    }
    if ($outputRootOwned -and
        (Test-Path -LiteralPath $script:WinAirPlaySignedPackageRoot)) {
        try {
            Remove-WinAirPlayDirectorySafe `
                -Path $script:WinAirPlaySignedPackageRoot `
                -AllowedParent $script:WinAirPlayProgramData `
                -AllowedLeafPattern '^WinAirPlayAudioSignedPackages$'
        }
        catch {
            $cleanupProblems.Add($_.Exception.Message)
        }
    }
    if ($cleanupProblems.Count -ne 0) {
        throw [InvalidOperationException]::new(
            "Test signing failed and rollback was incomplete: $($cleanupProblems -join '; ')",
            $signingFailure.Exception)
    }
    throw $signingFailure
}
finally {
    if ($toolSnapshot) {
        try {
            Remove-WinAirPlaySigningToolSnapshot `
                -SnapshotDirectory $toolSnapshot.SnapshotDirectory
        }
        catch {
            Write-Warning "Protected signing-tool snapshot cleanup failed: $($_.Exception.Message)"
        }
    }
    if ($snapshot) {
        try {
            Remove-WinAirPlayPackageSnapshot -SnapshotDirectory $snapshot
        }
        catch {
            Write-Warning "Protected signing snapshot cleanup failed: $($_.Exception.Message)"
        }
    }
    Exit-WinAirPlayInstallerMutex -Mutex $installerMutex
}
