[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$ExpectedSignerThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-WinAirPlayInstallerReleaseNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Installer release paths must not contain reparse points.'
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Remove-WinAirPlayInstallerReleaseScratch {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($full), [IO.Path]::GetFullPath($Parent)) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Refusing installer-release cleanup outside owned scratch.'
    }
    Assert-WinAirPlayInstallerReleaseNoLinks $full
    if (Test-Path -LiteralPath $full) {
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw 'Refusing installer-release cleanup containing a reparse point.'
        }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $full) { throw 'Installer-release scratch cleanup left residue.' }
    }
}

function Get-WinAirPlayInstallerReleaseSignature {
    param([Parameter(Mandatory)][string]$Path)
    return Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
}

function Get-WinAirPlayInstallerReleaseFileVersion {
    param([Parameter(Mandatory)][string]$Path)
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return [pscustomobject]@{
        Version = ('{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart,
            $info.FileBuildPart, $info.FilePrivatePart)
        Description = $info.FileDescription
    }
}

function Assert-WinAirPlayInstallerReleaseWizard {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$DriverVersion, [Parameter(Mandatory)][string]$SignerPin)
    Assert-WinAirPlayInstallerReleaseNoLinks $Path
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -ne $Record.Bytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Record.Sha256) {
        throw 'Installer release GUI bytes differ from the authenticated GUI inventory.'
    }
    $signature = Get-WinAirPlayInstallerReleaseSignature -Path $Path
    if ($signature.Status.ToString() -cne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne $SignerPin) {
        throw 'Installer release GUI must have a valid signature from the pinned signer.'
    }
    $resource = Get-WinAirPlayInstallerReleaseFileVersion -Path $Path
    if ($resource.Version -cne $DriverVersion -or $resource.Description -match '(?i)preview') {
        throw 'Installer release GUI Windows version or preview identity is invalid.'
    }
}

function Invoke-WinAirPlayInstallerRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    if ($ExpectedSignerThumbprint -cnotmatch '^[0-9A-F]{40}$') {
        throw 'Installer release requires the expected uppercase signer pin.'
    }
    # This is a projection of an already authenticated and signed internal
    # bundle. It never compiles, signs, imports trust or invokes the wizards.
    $inputLocks = [Collections.Generic.List[IDisposable]]::new()
    $outputHandles = [Collections.Generic.List[IDisposable]]::new()
    $outputLock = $null
    $scratch = $null
    $archiveOwned = $false
    $checksumOwned = $false
    $archiveName = "WinAirPlayAudio-$Version-windows-x64-test-signed.zip"
    $output = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($OutputDirectory))
    $finalArchive = Join-Path $output $archiveName
    $finalChecksum = "$finalArchive.sha256"
    $scratchParent = Join-Path $RepositoryRoot '.local/diagnostics/installer-release'
    try {
        foreach ($path in @($ArchivePath, $ChecksumPath)) {
            Assert-WinAirPlayInstallerReleaseNoLinks $path
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($file.PSIsContainer) { throw 'Installer release inputs must be regular files.' }
            $inputLocks.Add([IO.File]::Open($file.FullName, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        Assert-WinAirPlayInstallerReleaseNoLinks $output
        $null = [IO.Directory]::CreateDirectory($output)
        if ((Test-Path -LiteralPath $finalArchive) -or (Test-Path -LiteralPath $finalChecksum)) {
            throw 'Installer release output already exists; existing artifacts are never overwritten.'
        }
        $lockPath = Join-Path $output '.installer-release.lock'
        Assert-WinAirPlayInstallerReleaseNoLinks $lockPath
        $outputLock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        Assert-WinAirPlayInstallerReleaseNoLinks $scratchParent
        $null = [IO.Directory]::CreateDirectory($scratchParent)
        $scratch = Join-Path $scratchParent ([Guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($scratch)
        $expanded = Expand-WinAirPlayReleaseArchive -ArchivePath $ArchivePath -ChecksumPath $ChecksumPath `
            -Destination (Join-Path $scratch 'internal') -Version $Version -SourceCommit $SourceCommit `
            -SigningState test-signed -ExpectedSignerThumbprint $ExpectedSignerThumbprint
        $names = @("WinAirPlayAudio-$Version-Setup.exe", "WinAirPlayAudio-$Version-Uninstall.exe")
        $protectedNames = @('bundle-manifest.json', 'wizard-build.json', 'version.json',
            'package/version.json') + $names
        $wizardStreams = @{}
        foreach ($name in $protectedNames) {
            $path = Join-Path $expanded $name
            Assert-WinAirPlayInstallerReleaseNoLinks $path
            $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $inputLocks.Add($handle)
            if ($name -cin $names) { $wizardStreams[$name] = $handle }
        }
        # Bind the locked extracted files to the original locked archive,
        # including the manifest itself. Merely trusting a copied manifest
        # would leave a replace-before-lock window for the extraction tree.
        $sourceZip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
        try {
            foreach ($name in $protectedNames) {
                $sourceEntry = $sourceZip.GetEntry($name)
                $sourceStream = $sourceEntry.Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $sourceHash = [Convert]::ToHexString($sha.ComputeHash($sourceStream)) }
                finally { $sha.Dispose(); $sourceStream.Dispose() }
                $path = Join-Path $expanded $name
                if ((Get-Item -LiteralPath $path).Length -ne $sourceEntry.Length -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $sourceHash) {
                    throw 'Authenticated installer input changed before its read lock was acquired.'
                }
            }
        } finally { $sourceZip.Dispose() }
        # These same handles remain open through archive creation and verification.
        $outer = Get-Content -LiteralPath (Join-Path $expanded 'bundle-manifest.json') -Raw | ConvertFrom-Json -Depth 30
        foreach ($name in $protectedNames | Where-Object { $_ -cne 'bundle-manifest.json' }) {
            $record = @($outer.Files | Where-Object Name -CEQ $name)
            $path = Join-Path $expanded $name
            if ($record.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne $record[0].Length -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $record[0].Sha256) {
                throw 'Authenticated installer input changed before its read lock was acquired.'
            }
        }
        $canonical = Get-Content -LiteralPath (Join-Path $expanded 'version.json') -Raw | ConvertFrom-Json
        if ($canonical.schema_version -ne 1 -or $canonical.version -cne $Version -or
            ($canonical.driver_revision -isnot [int] -and $canonical.driver_revision -isnot [long]) -or
            $canonical.driver_revision -lt 0 -or $canonical.driver_revision -gt 65535 -or
            (Get-FileHash -LiteralPath (Join-Path $expanded 'version.json')).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $expanded 'package/version.json')).Hash) {
            throw 'Installer release canonical/package version identity is invalid.'
        }
        $driverVersion = ($Version -split '[-+]', 2)[0] + '.' + [string]$canonical.driver_revision
        if ($outer.DriverVersion -cne $driverVersion) { throw 'Installer release driver version anchor differs.' }
        $gui = Get-Content -LiteralPath (Join-Path $expanded 'wizard-build.json') -Raw | ConvertFrom-Json -Depth 30
        foreach ($name in $names) {
            $record = @($gui.Files | Where-Object Name -CEQ $name)
            if ($record.Count -ne 1) { throw 'Installer release GUI inventory must contain exactly both wizards.' }
            Assert-WinAirPlayInstallerReleaseWizard -Path (Join-Path $expanded $name) -Record $record[0] `
                -DriverVersion $driverVersion -SignerPin $ExpectedSignerThumbprint
        }
        $publishStage = Join-Path $scratch 'publish'
        $null = [IO.Directory]::CreateDirectory($publishStage)
        $stagedArchive = Join-Path $publishStage $archiveName
        $stagedChecksum = "$stagedArchive.sha256"
        $zip = [IO.Compression.ZipFile]::Open($stagedArchive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $names) {
                $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $stream = $entry.Open()
                try { $wizardStreams[$name].Position = 0; $wizardStreams[$name].CopyTo($stream) }
                finally { $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
        $stagedArchiveStream = [IO.File]::Open($stagedArchive, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $inputLocks.Add($stagedArchiveStream)
        $archiveHash = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash
        [IO.File]::WriteAllText($stagedChecksum, "$archiveHash  $archiveName`n", [Text.UTF8Encoding]::new($false))
        $stagedChecksumStream = [IO.File]::Open($stagedChecksum, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $inputLocks.Add($stagedChecksumStream)
        $verified = Expand-WinAirPlayInstallerArchive -ArchivePath $stagedArchive -ChecksumPath $stagedChecksum `
            -Destination (Join-Path $scratch 'verified') -Version $Version
        foreach ($name in $names) {
            $record = @($gui.Files | Where-Object Name -CEQ $name)[0]
            $path = Join-Path $verified $name
            $inputLocks.Add([IO.File]::Open($path, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::Read))
            Assert-WinAirPlayInstallerReleaseWizard -Path $path -Record $record `
                -DriverVersion $driverVersion -SignerPin $ExpectedSignerThumbprint
        }
        # CreateNew refuses output collisions. Hold deny-write/delete handles
        # while copying and checking the final delivered bytes and checksum.
        Assert-WinAirPlayInstallerReleaseNoLinks $output
        $archiveOutput = [IO.FileStream]::new($finalArchive, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $outputHandles.Add($archiveOutput)
        $archiveOwned = $true
        $stagedArchiveStream.Position = 0
        $stagedArchiveStream.CopyTo($archiveOutput)
        $archiveOutput.Flush($true)
        $archiveOutput.Dispose()
        $outputHandles.Add([IO.File]::Open($finalArchive, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read))
        $checksumOutput = [IO.FileStream]::new($finalChecksum, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $outputHandles.Add($checksumOutput)
        $checksumOwned = $true
        $stagedChecksumStream.Position = 0
        $stagedChecksumStream.CopyTo($checksumOutput)
        $checksumOutput.Flush($true)
        $checksumOutput.Dispose()
        $outputHandles.Add([IO.File]::Open($finalChecksum, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read))
        if ((Get-FileHash -LiteralPath $finalArchive -Algorithm SHA256).Hash -cne $archiveHash) {
            throw 'Final installer release archive differs from the verified stage.'
        }
        $null = Expand-WinAirPlayInstallerArchive -ArchivePath $finalArchive -ChecksumPath $finalChecksum `
            -Destination (Join-Path $scratch 'published-verified') -Version $Version
        return [pscustomobject]@{
            Archive = $finalArchive; ChecksumFile = $finalChecksum; ArchiveSha256 = $archiveHash
            ArchiveBytes = (Get-Item -LiteralPath $finalArchive).Length; Version = $Version
            SourceCommit = $SourceCommit; SignerThumbprint = $ExpectedSignerThumbprint
            Files = @($gui.Files); SigningState = 'test-signed'
        }
    }
    catch {
        foreach ($handle in $outputHandles) { $handle.Dispose() }
        $outputHandles.Clear()
        foreach ($owned in @(@{Path=$finalChecksum;Owned=$checksumOwned}, @{Path=$finalArchive;Owned=$archiveOwned})) {
            if ($owned.Owned) {
                Assert-WinAirPlayInstallerReleaseNoLinks $owned.Path
                if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($owned.Path), $output)) {
                    throw 'Refusing installer-release output cleanup outside the owned output directory.'
                }
                Remove-Item -LiteralPath $owned.Path -Force -ErrorAction Stop
            }
        }
        throw
    }
    finally {
        foreach ($handle in $outputHandles) { $handle.Dispose() }
        foreach ($handle in $inputLocks) { $handle.Dispose() }
        if ($outputLock) { $outputLock.Dispose() }
        if ($scratch) { Remove-WinAirPlayInstallerReleaseScratch -Path $scratch -Parent $scratchParent }
    }
}

Import-Module (Join-Path $PSScriptRoot 'ReleaseLayout.psm1') -Force
Invoke-WinAirPlayInstallerRelease -ArchivePath $ArchivePath -ChecksumPath $ChecksumPath `
    -OutputDirectory $OutputDirectory -Version $Version -SourceCommit $SourceCommit `
    -ExpectedSignerThumbprint $ExpectedSignerThumbprint -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
