Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer/Common.ps1')

function Get-WinAirPlayReleaseSourceFileNames {
    return @(
        'CONTRIBUTING.md', 'SECURITY.md', 'LICENSE',
        'THIRD_PARTY_NOTICES.md', 'version.json', 'CHANGELOG.md', 'AGENTS.md',
        'Setup.cmd', 'installer/Start-Setup.ps1',
        'installer/Setup-Dependencies.ps1', 'installer/Setup.ps1',
        'installer/Setup.Common.ps1',
        'Uninstall.cmd', 'installer/Start-Uninstall.ps1', 'installer/Uninstall.ps1',
        'installer/Uninstall.Common.ps1',
        'installer/Common.ps1', 'installer/Install-Driver.ps1',
        'installer/Uninstall-Driver.ps1', 'installer/Sign-TestPackage.ps1',
        'installer/New-TestCertificate.ps1', 'installer/Remove-TestCertificate.ps1',
        'installer/Set-TestSigning.ps1', 'installer/README.md',
        'installer/gui/Build-Wizards.ps1', 'installer/gui/Installer.iss',
        'installer/gui/Uninstaller.iss', 'installer/gui/Wizard.iss',
        'installer/gui/Invoke-WizardAction.ps1', 'installer/gui/README.md',
        'driver/packages.config', 'driver/LICENSE.microsoft-samples.txt',
        'docs/architecture.md', 'docs/build-and-install.md',
        'docs/known-limitations.md', 'docs/security.md',
        'docs/troubleshooting.md', 'docs/airplay-compatibility-and-licensing.md',
        'docs/DEFECTS.md', 'docs/development.md', 'docs/releasing.md',
        'docs/testing.md', 'docs/audio-pipeline.md', 'docs/driver-design.md',
        'docs/receiver-state-machine.md', 'docs/release-checklist.md',
        'docs/local-artifacts.md', 'docs/decisions.md', 'docs/risk-register.md',
        'docs/airplay2-single-receiver-spec.md',
        'docs/airplay2-stage-0-3-plan.md'
    )
}

function Get-WinAirPlayGuiFileNames {
    param([Parameter(Mandatory)][string]$Version)
    return @("WinAirPlayAudio-$Version-Setup.exe", "WinAirPlayAudio-$Version-Uninstall.exe", 'wizard-build.json')
}

function Assert-WinAirPlayGuiManifest {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$PackageManifestSha256,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint,
        [Parameter(Mandatory)][object]$Records
    )
    if ($Manifest.SchemaVersion -ne 1 -or $Manifest.SigningState -cne 'test-signed' -or $Manifest.Version -cne $Version -or
        $Manifest.SourceCommit -cne $SourceCommit -or $Manifest.PreviewOnly -isnot [bool] -or $Manifest.PreviewOnly -or
        $Manifest.PayloadManifestSha256 -cne $PackageManifestSha256 -or
        $Manifest.SignerThumbprint -cne $ExpectedSignerThumbprint) {
        throw 'Signed GUI metadata has invalid source, version, payload, signer or preview identity.'
    }
    $portableText = $Manifest | ConvertTo-Json -Depth 30
    if ($portableText -match '(?i)file://|(?<![A-Za-z])[A-Za-z]:[\\/]') {
        throw 'Signed GUI metadata contains private local paths.'
    }
    $names = @(Get-WinAirPlayGuiFileNames -Version $Version | Where-Object { $_ -cne 'wizard-build.json' })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Manifest.Files)) {
        if ([string]$item.Name -cnotin $names -or -not $seen.Add([string]$item.Name) -or
            -not $Records.ContainsKey([string]$item.Name) -or
            ($item.Bytes -isnot [int] -and $item.Bytes -isnot [long]) -or
            $item.Bytes -le 0 -or $item.Bytes -ne $Records[$item.Name].Length -or
            [string]$item.Sha256 -cnotmatch '^[0-9A-F]{64}$' -or
            $item.Sha256 -cne $Records[$item.Name].Sha256 -or
            $item.SignatureStatus -cne 'Valid' -or $item.SignerThumbprint -cne $ExpectedSignerThumbprint) {
            throw 'Signed GUI inventory has a missing, corrupt, unsigned or unexpected executable.'
        }
    }
    if ($seen.Count -ne 2) { throw 'Signed GUI inventory must contain exactly both wizard executables.' }
}


function Get-WinAirPlayPublicTestCertificate {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedThumbprint)
    if ($ExpectedThumbprint -cnotmatch '^[0-9A-F]{40}$') { throw 'Expected certificate thumbprint must be 40 uppercase hexadecimal characters.' }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Length -le 0 -or $file.Length -gt 64KB) { throw 'Public certificate must be a bounded regular DER file.' }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes) -ne
        [Security.Cryptography.X509Certificates.X509ContentType]::Cert) { throw 'Only one public DER certificate is accepted.' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
    $eku = @($certificate.Extensions |
        Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | Where-Object Value -CEQ '1.3.6.1.5.5.7.3.3')
    if ($certificate.HasPrivateKey -or $certificate.Thumbprint -cne $ExpectedThumbprint -or
        $certificate.Subject -cne $certificate.Issuer -or $eku.Count -ne 1 -or
        $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
        $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or
        -not [Linq.Enumerable]::SequenceEqual[byte]($bytes, $certificate.RawData)) {
        $certificate.Dispose()
        throw 'Public test certificate does not match the expected identity, validity, EKU or DER contract.'
    }
    return $certificate
}

# Checks the envelope and hashes, not Windows signing policy. The publisher
# additionally pins these exact bytes to the successful signing job.
function Expand-WinAirPlayReleaseArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][ValidateSet('unsigned', 'test-signed')][string]$SigningState,
        [string]$ExpectedSignerThumbprint
    )
    $numeric = '(?:0|[1-9][0-9]*)'
    $identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    $semver = "^$numeric\.$numeric\.$numeric(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
    if ($Version.Length -gt 128 -or $Version -cnotmatch $semver -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Archive validation requires canonical SemVer and source commit.'
    }
    $signed = $SigningState -ceq 'test-signed'
    $pin = ([string]$ExpectedSignerThumbprint).Replace(' ', '').ToUpperInvariant()
    if ($signed -and $pin -cnotmatch '^[0-9A-F]{40}$') { throw 'Test-signed archives require a signer pin.' }
    $assertNoLinks = {
        param([string]$Path)
        $current = [IO.Path]::GetFullPath($Path)
        while ($current) {
            if ((Test-Path -LiteralPath $current) -and
                ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Archive input/output contains a reparse point.'
            }
            $current = [IO.Path]::GetDirectoryName($current)
        }
    }
    $streamEntry = {
        param($Entry, [IO.Stream]$Output, [bool]$Capture)
        $inputStream = $Entry.Open()
        $memory = if ($Capture) { [IO.MemoryStream]::new() } else { $null }
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $buffer = [byte[]]::new(65536)
            [long]$length = 0
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $length += $count
                if ($length -gt $Entry.Length -or $length -gt 32MB) { throw 'ZIP payload exceeds its declared bound.' }
                $hash.AppendData($buffer, 0, $count)
                if ($Output) { $Output.Write($buffer, 0, $count) }
                if ($memory) { $memory.Write($buffer, 0, $count) }
            }
            if ($length -ne $Entry.Length) { throw 'ZIP payload length is inconsistent.' }
            [pscustomobject]@{ Length=$length; Sha256=[Convert]::ToHexString($hash.GetHashAndReset())
                Bytes=if ($memory) { $memory.ToArray() } else { $null } }
        }
        finally {
            $inputStream.Dispose(); $hash.Dispose()
            if ($memory) { $memory.Dispose() }
        }
    }
    $archiveName = "WinAirPlayAudio-$Version-windows-x64-$SigningState.zip"
    foreach ($path in @($ArchivePath, $ChecksumPath, $Destination)) { & $assertNoLinks $path }
    $archiveFile = Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    $checksumFile = Get-Item -LiteralPath $ChecksumPath -Force -ErrorAction Stop
    if ($archiveFile.PSIsContainer -or $archiveFile.Name -cne $archiveName -or
        $archiveFile.Length -le 0 -or $archiveFile.Length -gt 128MB -or
        $checksumFile.PSIsContainer -or $checksumFile.Name -cne "$archiveName.sha256" -or
        $checksumFile.Length -le 0 -or $checksumFile.Length -gt 512) { throw 'Archive/checksum file contract is invalid.' }
    $checksumText = [IO.File]::ReadAllText($checksumFile.FullName).TrimEnd("`r", "`n")
    if ($checksumText -cnotmatch ('^([0-9A-Fa-f]{64}) [ *]' + [regex]::Escape($archiveName) + '$')) {
        throw 'Checksum must contain exactly the expected archive name and digest.'
    }
    $expectedHash = $Matches[1].ToUpperInvariant()
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $parent = [IO.Path]::GetDirectoryName($destinationRoot)
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container) -or
        (Test-Path -LiteralPath $destinationRoot)) { throw 'Extraction requires a new destination beneath an existing directory.' }
    $expected = @(Get-WinAirPlayReleaseSourceFileNames) + @('README.md', 'INSTALL.md', 'bundle-manifest.json') +
        @(Get-WinAirPlayPackageFileNames | ForEach-Object { "package/$_" })
    if ($signed) { $expected += 'test-signing.cer'; $expected += @(Get-WinAirPlayGuiFileNames -Version $Version) }
    $allowed = [Collections.Generic.HashSet[string]]::new([string[]]$expected, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $records = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $fileStream=$null; $zip=$null; $owned=$false
    try {
        $fileStream = [IO.FileStream]::new($archiveFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [Convert]::ToHexString($sha.ComputeHash($fileStream)) } finally { $sha.Dispose() }
        if ($actualHash -cne $expectedHash) { throw 'Archive checksum mismatch.' }
        $fileStream.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($zip.Entries.Count -ne $allowed.Count) { throw 'ZIP contains an unexpected file count.' }
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (-not $allowed.Contains($name) -or -not $seen.Add($name) -or $name.Contains('\') -or
                $name -match '(^/|//|(?:^|/)\.\.?(?:/|$)|:)' -or ($entry.ExternalAttributes -band 0x410) -ne 0 -or
                $entry.Length -lt 0 -or $entry.Length -gt 32MB) { throw 'ZIP contains an unsafe, duplicate, oversized or unexpected entry.' }
            $total += $entry.Length
            if ($total -gt 160MB) { throw 'ZIP exceeds its total expanded-size bound.' }
            $capture = $name -in @('bundle-manifest.json', 'package/package-manifest.json',
                'version.json', 'package/version.json', 'test-signing.cer', 'wizard-build.json')
            if ($capture -and $entry.Length -gt 1MB) { throw 'ZIP metadata exceeds its size bound.' }
            $entries.Add($name, $entry)
            $records.Add($name, (& $streamEntry $entry $null $capture))
        }
        $manifest = [Text.Encoding]::UTF8.GetString($records['bundle-manifest.json'].Bytes) | ConvertFrom-Json -Depth 30
        if ($manifest.SchemaVersion -ne 1 -or $manifest.Version -cne $Version -or $manifest.Configuration -cne 'Release' -or
            $manifest.SigningState -cne $SigningState -or $manifest.SourceCommit -cne $SourceCommit -or
            $manifest.AssemblySourceCommit -cne $SourceCommit -or $manifest.SourceTreeDirty -isnot [bool] -or
            $manifest.SourceTreeDirty -or $manifest.AssemblySourceTreeDirty -isnot [bool] -or $manifest.AssemblySourceTreeDirty) {
            throw 'Bundle provenance/state is invalid.'
        }
        $inventory = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in @($manifest.Files)) {
            if ($item.Name -ceq 'bundle-manifest.json' -or -not $records.ContainsKey([string]$item.Name) -or
                -not $inventory.Add([string]$item.Name) -or ($item.Length -isnot [int] -and $item.Length -isnot [long]) -or
                $item.Length -ne $records[$item.Name].Length -or [string]$item.Sha256 -cnotmatch '^[0-9A-Fa-f]{64}$' -or
                $item.Sha256.ToUpperInvariant() -cne $records[$item.Name].Sha256) { throw 'Bundle inventory/hash mismatch.' }
        }
        if ($inventory.Count -ne $records.Count - 1) { throw 'Bundle inventory is incomplete.' }
        $versionRecord = [Text.Encoding]::UTF8.GetString($records['version.json'].Bytes) | ConvertFrom-Json
        if ($versionRecord.schema_version -ne 1 -or $versionRecord.version -cne $Version -or
            $records['version.json'].Sha256 -cne $records['package/version.json'].Sha256) { throw 'Canonical/package versions disagree.' }
        $packageHash = $records['package/package-manifest.json'].Sha256
        if ([string]$manifest.UnsignedPackageManifestSha256 -cnotmatch '^[0-9A-Fa-f]{64}$') { throw 'Unsigned manifest anchor is invalid.' }
        $packageManifest = [Text.Encoding]::UTF8.GetString($records['package/package-manifest.json'].Bytes) | ConvertFrom-Json -Depth 30
        if ($signed) {
            if ($manifest.SignedPackageManifestSha256 -cne $packageHash -or $manifest.SignerThumbprint -cne $pin -or
                $packageManifest.UnsignedManifestSha256 -cne $manifest.UnsignedPackageManifestSha256) { throw 'Signed manifest anchors disagree.' }
            $guiManifest = [Text.Encoding]::UTF8.GetString($records['wizard-build.json'].Bytes) | ConvertFrom-Json -Depth 30
            Assert-WinAirPlayGuiManifest -Manifest $guiManifest -Version $Version -SourceCommit $SourceCommit `
                -PackageManifestSha256 $packageHash -ExpectedSignerThumbprint $pin -Records $records
            [byte[]]$certBytes = $records['test-signing.cer'].Bytes
            if ($certBytes.Length -gt 64KB -or [Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($certBytes) -ne
                [Security.Cryptography.X509Certificates.X509ContentType]::Cert) { throw 'Public certificate must be one public DER certificate.' }
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
            try {
                if ($certificate.HasPrivateKey -or $certificate.Thumbprint -cne $pin -or
                    -not [Linq.Enumerable]::SequenceEqual[byte]($certBytes, $certificate.RawData)) { throw 'Public certificate does not match the signer pin/DER contract.' }
            } finally { $certificate.Dispose() }
        }
        elseif ($manifest.UnsignedPackageManifestSha256 -cne $packageHash) { throw 'Unsigned manifest anchor disagrees.' }
        if ($packageManifest.SchemaVersion -ne 1 -or $packageManifest.SourceCommit -cne $SourceCommit -or
            $packageManifest.SourceTreeDirty -isnot [bool] -or $packageManifest.SourceTreeDirty -or
            $packageManifest.Configuration -cne 'Release' -or $packageManifest.Platform -cne 'x64' -or
            $packageManifest.HardwareId -cne 'ROOT\WinAirPlayAudio' -or $packageManifest.UserService -cne 'WinAirPlayAudioService') {
            throw 'Package provenance/identity is invalid.'
        }
        $packageNames = @(Get-WinAirPlayPackageFileNames | Where-Object { $_ -cne 'package-manifest.json' })
        # Windows tooling may lowercase a catalog basename in the authenticated
        # package manifest. The ZIP itself retains the exact canonical allowlist.
        $canonicalNames = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $packageNames) { $canonicalNames.Add($name, $name) }
        $packageSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($packageManifest.Files)) {
            if (-not $canonicalNames.ContainsKey([string]$item.Name) -or -not $packageSeen.Add([string]$item.Name)) {
                throw 'Package inventory contains an unexpected or duplicate Windows filename.'
            }
            $record = $records['package/' + $canonicalNames[[string]$item.Name]]
            if (
                ($item.Length -isnot [int] -and $item.Length -isnot [long]) -or
                $item.Length -ne $record.Length -or [string]$item.Sha256 -cnotmatch '^[0-9A-Fa-f]{64}$' -or
                $item.Sha256.ToUpperInvariant() -cne $record.Sha256) { throw 'Package inventory/hash mismatch.' }
            if ([IO.Path]::GetExtension($item.Name) -in @('.cat', '.sys', '.exe')) {
                if (($signed -and ($item.SignatureStatus -cne 'Valid' -or $item.SignerThumbprint -cne $pin)) -or
                    (-not $signed -and ($item.SignatureStatus -cne 'NotSigned' -or $item.SignerThumbprint))) {
                    throw 'Package signature metadata does not match its declared state.'
                }
            }
        }
        if ($packageSeen.Count -ne $packageNames.Count) { throw 'Package inventory is incomplete.' }
        New-Item -ItemType Directory -Path $destinationRoot -ErrorAction Stop | Out-Null
        $owned = $true
        foreach ($name in $entries.Keys) {
            $target = Join-Path $destinationRoot $name
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            & $assertNoLinks $target
            $output = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $null = & $streamEntry $entries[$name] $output $false } finally { $output.Dispose() }
        }
        return $destinationRoot
    }
    catch {
        if ($owned) {
            & $assertNoLinks $destinationRoot
            if (@(Get-ChildItem -LiteralPath $destinationRoot -Recurse -Force |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Extraction failed; cleanup rejected a reparse point.' }
            Remove-Item -LiteralPath $destinationRoot -Recurse -Force -ErrorAction Stop
        }
        throw
    }
    finally {
        if ($zip) { $zip.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
    }
}

# The public download has no loose manifests or certificate. This reader checks
# only its two-file envelope and checksum; the signing job's trusted archive hash
# binds those bytes to the separately verified source, payload and signatures.
function Expand-WinAirPlayInstallerArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Version
    )
    $numeric = '(?:0|[1-9][0-9]*)'
    $identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    $semver = "^$numeric\.$numeric\.$numeric(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
    if ($Version.Length -gt 128 -or $Version -cnotmatch $semver) {
        throw 'Installer archive validation requires canonical SemVer.'
    }
    $assertNoLinks = {
        param([string]$Path)
        $current = [IO.Path]::GetFullPath($Path)
        while ($current) {
            if ((Test-Path -LiteralPath $current) -and
                ((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Installer archive input/output contains a reparse point.'
            }
            $current = [IO.Path]::GetDirectoryName($current)
        }
    }
    foreach ($path in @($ArchivePath, $ChecksumPath, $Destination)) { & $assertNoLinks $path }
    $archiveName = "WinAirPlayAudio-$Version-windows-x64-test-signed.zip"
    $archiveFile = Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    $checksumFile = Get-Item -LiteralPath $ChecksumPath -Force -ErrorAction Stop
    if ($archiveFile.PSIsContainer -or $archiveFile.Name -cne $archiveName -or
        $archiveFile.Length -le 0 -or $archiveFile.Length -gt 128MB -or
        $checksumFile.PSIsContainer -or $checksumFile.Name -cne "$archiveName.sha256" -or
        $checksumFile.Length -le 0 -or $checksumFile.Length -gt 512) {
        throw 'Installer archive/checksum file contract is invalid.'
    }
    $checksumStream = [IO.FileStream]::new($checksumFile.FullName, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($checksumStream.Length -le 0 -or $checksumStream.Length -gt 512) {
            throw 'Installer checksum exceeds its size bound.'
        }
        $checksumBytes = [byte[]]::new([int]$checksumStream.Length)
        $checksumStream.ReadExactly($checksumBytes)
    }
    finally { $checksumStream.Dispose() }
    $checksumText = [Text.UTF8Encoding]::new($false, $true).GetString($checksumBytes).TrimEnd("`r", "`n")
    if ($checksumText -cnotmatch ('^([0-9A-Fa-f]{64}) [ *]' + [regex]::Escape($archiveName) + '$')) {
        throw 'Installer checksum must contain exactly the expected archive name and digest.'
    }
    $expectedHash = $Matches[1].ToUpperInvariant()
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $destinationParent = [IO.Path]::GetDirectoryName($destinationRoot)
    if (-not $destinationParent -or -not (Test-Path -LiteralPath $destinationParent -PathType Container) -or
        (Test-Path -LiteralPath $destinationRoot)) {
        throw 'Installer extraction requires a new destination beneath an existing directory.'
    }
    $names = @("WinAirPlayAudio-$Version-Setup.exe", "WinAirPlayAudio-$Version-Uninstall.exe")
    $allowed = [Collections.Generic.HashSet[string]]::new([string[]]$names, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fileStream = $null; $zip = $null; $owned = $false
    try {
        # Hold the archive open without write/delete sharing through validation
        # and extraction so a successful checksum cannot precede replaced bytes.
        $fileStream = [IO.FileStream]::new($archiveFile.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($fileStream.Length -le 0 -or $fileStream.Length -gt 128MB) {
            throw 'Installer archive exceeds its size bound.'
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [Convert]::ToHexString($hash.ComputeHash($fileStream)) }
        finally { $hash.Dispose() }
        if ($actualHash -cne $expectedHash) { throw 'Installer archive checksum mismatch.' }
        $fileStream.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($zip.Entries.Count -ne 2) { throw 'Installer ZIP must contain exactly the Setup and Uninstall executables.' }
        foreach ($entry in $zip.Entries) {
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if (-not $allowed.Contains($entry.FullName) -or -not $seen.Add($entry.FullName) -or
                ($entry.ExternalAttributes -band 0x410) -ne 0 -or $unixType -notin @(0, 0x8000) -or
                $entry.Length -le 0 -or $entry.Length -gt 32MB) {
                throw 'Installer ZIP contains an unsafe, duplicate, empty, oversized or unexpected entry.'
            }
        }
        & $assertNoLinks $destinationRoot
        New-Item -ItemType Directory -Path $destinationRoot -ErrorAction Stop | Out-Null
        $owned = $true
        foreach ($entry in $zip.Entries) {
            $target = Join-Path $destinationRoot $entry.FullName
            & $assertNoLinks $target
            $inputStream = $null; $outputStream = $null
            try {
                $inputStream = $entry.Open()
                $outputStream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = [byte[]]::new(65536)
                [long]$length = 0
                while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $length += $count
                    if ($length -gt $entry.Length -or $length -gt 32MB) {
                        throw 'Installer ZIP payload exceeds its declared size bound.'
                    }
                    $outputStream.Write($buffer, 0, $count)
                }
                if ($length -ne $entry.Length) { throw 'Installer ZIP payload length is inconsistent.' }
            }
            finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
            }
        }
        return $destinationRoot
    }
    catch {
        if ($owned) {
            & $assertNoLinks $destinationRoot
            if ([IO.Path]::GetDirectoryName($destinationRoot) -cne $destinationParent -or
                @(Get-ChildItem -LiteralPath $destinationRoot -Recurse -Force |
                    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                throw 'Installer extraction failed; cleanup rejected its destination.'
            }
            Remove-Item -LiteralPath $destinationRoot -Recurse -Force -ErrorAction Stop
        }
        throw
    }
    finally {
        if ($zip) { $zip.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
    }
}

Export-ModuleMember -Function Get-WinAirPlayReleaseSourceFileNames, Get-WinAirPlayGuiFileNames, Assert-WinAirPlayGuiManifest, Get-WinAirPlayPublicTestCertificate, Expand-WinAirPlayReleaseArchive, Expand-WinAirPlayInstallerArchive
