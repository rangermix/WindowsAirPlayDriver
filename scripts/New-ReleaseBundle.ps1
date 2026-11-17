[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$OutputDirectory,
    [switch]$AllowDirty,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$PackageDirectory,
    [ValidateSet('unsigned', 'test-signed')][string]$SigningState = 'unsigned',
    [string]$ExpectedSignerThumbprint,
    [string]$ExpectedSignedManifestSha256,
    [string]$PublicCertificatePath,
    [string]$GuiDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleaseLayout.psm1') -Force

function Assert-WinAirPlayReleaseAncestors {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Release input/output contains a reparse point: $current"
            }
        }
        $parent = Split-Path -Path $current -Parent
        if ($parent -ceq $current) { break }
        $current = $parent
    }
}

function Get-WinAirPlayReleaseRegularFile {
    param([Parameter(Mandatory)][string]$Path)
    Assert-WinAirPlayReleaseAncestors -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 32MB) {
        throw "Release input is not a bounded regular file: $Path"
    }
    return $item
}

function Get-WinAirPlayReleaseVersion {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $gate = Join-Path $RepositoryRoot 'scripts/Version.ps1'
    $null = Get-WinAirPlayReleaseRegularFile -Path $gate
    $state = @(& $gate -Check -RepositoryRoot $RepositoryRoot)
    if ($state.Count -ne 1) {
        throw 'Version consistency gate did not return one canonical version.'
    }
    return $state[0]
}

function Get-WinAirPlayReleaseDriverVersion {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-WinAirPlayReleaseRegularFile -Path $Path
    $version = $file.VersionInfo
    if ([string]::IsNullOrWhiteSpace($version.FileVersion)) {
        throw 'Packaged SYS has no Windows file-version resource.'
    }
    return '{0}.{1}.{2}.{3}' -f $version.FileMajorPart, $version.FileMinorPart,
        $version.FileBuildPart, $version.FilePrivatePart
}

function Get-WinAirPlayReleaseAuthenticodeState {
    param([Parameter(Mandatory)][string]$Path)
    return Get-AuthenticodeSignature -LiteralPath $Path
}

function Assert-WinAirPlayReleaseBinaryPrivacy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$BuilderRoots
    )
    $file = Get-WinAirPlayReleaseRegularFile -Path $Path
    $binaryText = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
    foreach ($root in @($BuilderRoots | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -gt 3
        } | Sort-Object -Unique)) {
        foreach ($form in @($root.Replace('/', '\'), $root.Replace('\', '/')) | Select-Object -Unique) {
            foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                $needle = [Text.Encoding]::Latin1.GetString($encoding.GetBytes($form))
                if ($binaryText.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    throw "Packaged binary contains an original builder/profile path: $($file.Name)"
                }
            }
        }
    }
}

function Assert-WinAirPlayReleasePackage {
    param(
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][object]$VersionState,
        [Parameter(Mandatory)][string]$Configuration,
        [string[]]$BuilderRoots = @($RepositoryRoot, $env:USERPROFILE, $env:CARGO_HOME, $env:RUSTUP_HOME),
        [ValidateSet('unsigned', 'test-signed')][string]$SigningState = 'unsigned',
        [string]$ExpectedSignerThumbprint,
        [string]$ExpectedSignedManifestSha256
    )
    Assert-WinAirPlayReleaseAncestors -Path $PackageDirectory
    $BuilderRoots = @($BuilderRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $expectedNames = @(Get-WinAirPlayPackageFileNames)
    $entries = @(Get-ChildItem -LiteralPath $PackageDirectory -Force -ErrorAction Stop)
    $actualNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($entries.Count -ne $expectedNames.Count -or
        @($entries | Where-Object {
            $_.PSIsContainer -or $_.Name -notin $expectedNames -or -not $actualNames.Add($_.Name)
        }).Count -ne 0 -or
        @($expectedNames | Where-Object { -not $actualNames.Contains($_) }).Count -ne 0) {
        throw 'Release package must contain the exact authenticated payload file set.'
    }
    [int64]$total = 0
    foreach ($entry in $entries) {
        $file = Get-WinAirPlayReleaseRegularFile -Path $entry.FullName
        $total += $file.Length
        if ($total -gt 128MB) { throw 'Release package exceeds 128 MiB.' }
    }
    $package = Resolve-WinAirPlayPackage -PackageDirectory $PackageDirectory
    foreach ($binary in @($entries | Where-Object Extension -In @('.exe', '.sys'))) {
        Assert-WinAirPlayReleaseBinaryPrivacy -Path $binary.FullName -BuilderRoots $BuilderRoots
    }
    $manifest = Get-Content -LiteralPath $package.Manifest -Raw | ConvertFrom-Json
    if ($manifest.Configuration -cne $Configuration) {
        throw 'Release package configuration does not match the requested configuration.'
    }
    if ($manifest.PSObject.Properties.Name -cnotcontains 'SourceCommit' -or
        $manifest.PSObject.Properties.Name -cnotcontains 'SourceTreeDirty' -or
        [string]$manifest.SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $manifest.SourceTreeDirty -isnot [bool]) {
        throw 'Release package lacks valid source-commit/dirty-tree build provenance; rebuild the package.'
    }
    if ($SigningState -ceq 'test-signed') {
        if ($ExpectedSignerThumbprint -cnotmatch '^[0-9A-F]{40}$' -or
            $ExpectedSignedManifestSha256 -cnotmatch '^[0-9A-F]{64}$' -or
            (Get-FileHash -LiteralPath $package.Manifest -Algorithm SHA256).Hash -cne $ExpectedSignedManifestSha256 -or
            $manifest.PSObject.Properties.Name -cnotcontains 'UnsignedManifestSha256' -or
            $manifest.UnsignedManifestSha256 -cnotmatch '^[0-9A-F]{64}$') {
            throw 'Test-signed release requires pinned signer and final signed-manifest/preimage hashes.'
        }
    }
    foreach ($entry in @($manifest.Files)) {
        $path = Join-Path $PackageDirectory $entry.Name
        if ($entry.Length -ne (Get-Item -LiteralPath $path).Length) {
            throw 'Release package manifest contains an incorrect payload length.'
        }
        if ([IO.Path]::GetExtension($entry.Name) -notin @('.cat', '.sys', '.exe')) { continue }
        $signature = Get-WinAirPlayReleaseAuthenticodeState -Path $path
        if ($SigningState -ceq 'unsigned') {
            if ($entry.SignatureStatus -cne 'NotSigned' -or
                -not [string]::IsNullOrWhiteSpace([string]$entry.SignerThumbprint)) {
                throw 'Unsigned release input contains a signed or ambiguous manifest entry.'
            }
            if ($signature.Status.ToString() -cne 'NotSigned' -or $signature.SignerCertificate) {
                throw 'Unsigned release input has an existing or ambiguous Authenticode signature.'
            }
        }
        elseif ($entry.SignatureStatus -cne 'Valid' -or
            $entry.SignerThumbprint -cne $ExpectedSignerThumbprint -or
            $signature.Status.ToString() -cne 'Valid' -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -cne $ExpectedSignerThumbprint) {
            throw 'Test-signed release contains an unsigned, invalid, or unexpected signer.'
        }
    }
    $canonicalVersion = Join-Path $RepositoryRoot 'version.json'
    $packagedVersion = Join-Path $PackageDirectory 'version.json'
    if ((Get-FileHash -LiteralPath $canonicalVersion -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $packagedVersion -Algorithm SHA256).Hash) {
        throw 'Packaged version.json differs from the canonical version file.'
    }
    if ((Get-WinAirPlayReleaseDriverVersion -Path $package.Sys) -cne $VersionState.DriverVersion) {
        throw 'Packaged SYS file version differs from the canonical driver version.'
    }
    $infText = Get-Content -LiteralPath $package.Inf -Raw
    $driverVer = [regex]::Matches($infText, '(?im)^\s*DriverVer\s*=\s*([^,\r\n]+),\s*([^\r\n]+)\s*$')
    $expectedDate = [DateTime]::ParseExact(
        $VersionState.DriverDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).
        ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
    if ($driverVer.Count -ne 1 -or
        $driverVer[0].Groups[1].Value.Trim() -cne $expectedDate -or
        $driverVer[0].Groups[2].Value.Trim() -cne $VersionState.DriverVersion) {
        throw 'Packaged INF DriverVer differs from the canonical driver date/version.'
    }
    $inventoryPath = Join-Path $PackageDirectory 'cargo-metadata.json'
    $inventoryText = Get-Content -LiteralPath $inventoryPath -Raw
    $inventory = $inventoryText | ConvertFrom-Json -Depth 100
    if ($inventory.inventory_format -cne 'winairplay-cargo-dependency-inventory-v1' -or
        $inventoryText -match '(?i)file://|(?<![A-Za-z])[A-Za-z]:[\\/]|manifest_path|src_path|workspace_root|target_directory') {
        throw 'Packaged dependency inventory contains local paths or has an unsupported public format.'
    }
    return $package
}

function Assert-WinAirPlayReleaseGui {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GuiDirectory,
        [Parameter(Mandatory)][object]$VersionState,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$ExpectedSignedManifestSha256,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint,
        [Parameter(Mandatory)][string[]]$BuilderRoots,
        [switch]$AllowOtherEntries
    )
    if ([string]::IsNullOrWhiteSpace($GuiDirectory)) { throw 'Test-signed assembly requires the signed GUI directory.' }
    Assert-WinAirPlayReleaseAncestors -Path $GuiDirectory
    $directory = Get-Item -LiteralPath $GuiDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer) { throw 'Signed GUI input must be a directory.' }
    $names = @(Get-WinAirPlayGuiFileNames -Version $VersionState.Version)
    if (-not $AllowOtherEntries) {
        $entries = @(Get-ChildItem -LiteralPath $GuiDirectory -Force -ErrorAction Stop)
        if ($entries.Count -ne 3 -or @($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $names }).Count) {
            throw 'Signed GUI directory must contain exactly both wizard executables and wizard-build.json.'
        }
    }
    $records = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($name in $names) {
        $path = Join-Path $directory.FullName $name
        $file = Get-WinAirPlayReleaseRegularFile -Path $path
        if ($file.Length -le 0 -or ($name -ceq 'wizard-build.json' -and $file.Length -gt 1MB)) {
            throw 'Signed GUI file has an invalid bounded size.'
        }
        $records.Add($name, [pscustomobject]@{ Length=$file.Length; Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash })
        if ($file.Extension -ceq '.exe') {
            Assert-WinAirPlayPeX64 -Path $path
            Assert-WinAirPlayReleaseBinaryPrivacy -Path $path -BuilderRoots $BuilderRoots
            if ((Get-WinAirPlayReleaseDriverVersion -Path $path) -cne $VersionState.DriverVersion) {
                throw 'Signed GUI Windows file version differs from the canonical version.'
            }
            $signature = Get-WinAirPlayReleaseAuthenticodeState -Path $path
            if ($signature.Status.ToString() -cne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Thumbprint -cne $ExpectedSignerThumbprint) {
                throw 'Signed GUI executable is unsigned, invalid or signed by an unexpected signer.'
            }
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $directory.FullName 'wizard-build.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-WinAirPlayGuiManifest -Manifest $manifest -Version $VersionState.Version -SourceCommit $SourceCommit `
        -PackageManifestSha256 $ExpectedSignedManifestSha256 -ExpectedSignerThumbprint $ExpectedSignerThumbprint -Records $records
}

function Copy-WinAirPlayReleaseFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $file = Get-WinAirPlayReleaseRegularFile -Path $Source
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $outputStream = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($inputStream.Length -ne $file.Length -or $inputStream.Length -gt 32MB) {
            throw 'Release input changed or exceeded its copy bound.'
        }
        $inputStream.CopyTo($outputStream)
        if ($outputStream.Length -ne $file.Length) { throw 'Release input changed while copying.' }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
}

function Remove-WinAirPlayReleaseStage {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-Path -LiteralPath $Stage)) { return }
    $fullStage = (Resolve-Path -LiteralPath $Stage -ErrorAction Stop).Path
    $fullOutput = (Resolve-Path -LiteralPath $OutputDirectory -ErrorAction Stop).Path
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($fullStage), $fullOutput) -or
        [IO.Path]::GetFileName($fullStage) -cnotmatch '^\.bundle-stage-[0-9a-f]{32}$') {
        throw 'Refusing release-stage cleanup outside the owned output directory.'
    }
    Assert-WinAirPlayReleaseAncestors -Path $fullStage
    if (@(Get-ChildItem -LiteralPath $fullStage -Force -Recurse |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) {
        throw 'Refusing recursive cleanup of a release stage containing reparse points.'
    }
    Remove-Item -LiteralPath $fullStage -Recurse -Force -ErrorAction Stop
}

function Remove-WinAirPlayReleaseArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ExpectedName
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullOutput = [IO.Path]::GetFullPath($OutputDirectory)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($fullPath), $fullOutput) -or
        [IO.Path]::GetFileName($fullPath) -cne $ExpectedName) {
        throw 'Refusing release-artifact cleanup outside the owned output path.'
    }
    Assert-WinAirPlayReleaseAncestors -Path $fullPath
    $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($file.PSIsContainer) { throw 'Refusing release-artifact cleanup of a directory.' }
    Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
}

function Update-WinAirPlayReleaseDocumentation {
    param([Parameter(Mandatory)][string]$Stage)
    foreach ($file in @(Get-ChildItem -LiteralPath $Stage -Filter '*.md' -Recurse -File)) {
        $relative = [IO.Path]::GetRelativePath($Stage, $file.FullName).Replace('\', '/')
        # These are the exact authenticated signing-input bytes, not editable
        # bundle handoff documentation. INSTALL.md identifies them as snapshots.
        if ($relative.StartsWith('package/', [StringComparison]::Ordinal) -or $relative -ceq 'INSTALL.md') { continue }
        $parent = [IO.Path]::GetDirectoryName($file.FullName)
        $text = [IO.File]::ReadAllText($file.FullName)
        $text = [regex]::Replace($text, '(?<!!)\[(?<label>[^\]\r\n]+)\]\((?<target><[^>\r\n]+>|[^)\s]+)(?:\s+"[^"]*")?\)', {
            param($match)
            $target = $match.Groups['target'].Value.Trim('<', '>')
            if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:|^#') { return $match.Value }
            $targetPath = [Uri]::UnescapeDataString(($target -split '#', 2)[0])
            if ([string]::IsNullOrEmpty($targetPath)) { return $match.Value }
            $resolved = [IO.Path]::GetFullPath((Join-Path $parent $targetPath))
            if (Test-Path -LiteralPath $resolved) { return $match.Value }
            return '{0} (source checkout: `{1}`)' -f $match.Groups['label'].Value, $target
        })
        $installLink = [IO.Path]::GetRelativePath($parent, (Join-Path $Stage 'INSTALL.md')).Replace('\', '/')
        $banner = "> Source-checkout reference. This bounded release bundle does not include a buildable source tree. Follow [INSTALL.md]($installLink) for this artifact; source-only links below are labeled explicitly.`n`n"
        [IO.File]::WriteAllText($file.FullName, $banner + $text, [Text.UTF8Encoding]::new($false))
    }
}

function Invoke-WinAirPlayReleaseBundle {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
        [string]$OutputDirectory,
        [switch]$AllowDirty,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$PackageDirectory,
        [ValidateSet('unsigned', 'test-signed')][string]$SigningState = 'unsigned',
        [string]$ExpectedSignerThumbprint,
        [string]$ExpectedSignedManifestSha256,
        [string]$PublicCertificatePath,
        [string]$GuiDirectory
    )
    if ($SigningState -ceq 'unsigned' -and ($ExpectedSignerThumbprint -or
        $ExpectedSignedManifestSha256 -or $PublicCertificatePath -or $GuiDirectory)) {
        throw 'Unsigned assembly does not accept signing inputs.'
    }
    if ($SigningState -ceq 'test-signed') {
        $certificate = Get-WinAirPlayPublicTestCertificate -Path $PublicCertificatePath -ExpectedThumbprint $ExpectedSignerThumbprint
        $certificate.Dispose()
    }
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    Assert-WinAirPlayReleaseAncestors -Path $root
    $gitRoot = @(& git -C $root rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0 -or $gitRoot.Count -ne 1 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($gitRoot[0]), $root)) {
        throw 'Release source must be the root of a Git checkout.'
    }
    $hygiene = Join-Path $root 'scripts/Test-SourceHygiene.ps1'
    $null = Get-WinAirPlayReleaseRegularFile -Path $hygiene
    & $hygiene -RepositoryRoot $root
    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect release source status.' }
    if (-not $AllowDirty -and $status.Count -ne 0) {
        throw 'Release assembly requires a clean committed checkout; -AllowDirty is for local previews only.'
    }
    $sourceCommit = @(& git -C $root rev-parse --verify HEAD)
    if ($LASTEXITCODE -ne 0 -or $sourceCommit.Count -ne 1) {
        throw 'Release assembly requires a recorded source commit.'
    }
    $version = Get-WinAirPlayReleaseVersion -RepositoryRoot $root
    if ($version.Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw 'Canonical product version is not a safe SemVer archive name.'
    }
    $common = Join-Path $root 'installer/Common.ps1'
    $null = Get-WinAirPlayReleaseRegularFile -Path $common
    . $common
    if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
        $PackageDirectory = Join-Path $root "driver/out/package/$Configuration/x64"
    }
    $builderRoots = @(@($root, $env:USERPROFILE, $env:CARGO_HOME, $env:RUSTUP_HOME) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $package = Assert-WinAirPlayReleasePackage -PackageDirectory $PackageDirectory `
        -RepositoryRoot $root -VersionState $version -Configuration $Configuration -BuilderRoots $builderRoots `
        -SigningState $SigningState -ExpectedSignerThumbprint $ExpectedSignerThumbprint `
        -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256
    $packageManifest = Get-Content -LiteralPath $package.Manifest -Raw | ConvertFrom-Json
    if ($SigningState -ceq 'test-signed') {
        Assert-WinAirPlayReleaseGui -GuiDirectory $GuiDirectory -VersionState $version -SourceCommit $sourceCommit[0] `
            -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 -ExpectedSignerThumbprint $ExpectedSignerThumbprint -BuilderRoots $builderRoots
    }
    if (-not $AllowDirty -and ($packageManifest.SourceCommit -cne $sourceCommit[0] -or
            $packageManifest.SourceTreeDirty)) {
        throw 'Release package was not built from this clean source commit; rebuild it before normal release assembly.'
    }
    $binaryProvenance = if ($packageManifest.SourceTreeDirty -or
        $packageManifest.SourceCommit -cne $sourceCommit[0] -or $status.Count -ne 0) {
        'Unverified source preview: package or assembly source is dirty or differs; no exact binary-to-current-HEAD claim.'
    }
    else {
        'Package records a clean build from the assembly source commit.'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $root 'target/release'
    }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    if ([StringComparer]::OrdinalIgnoreCase.Equals($output, $package.Directory) -or
        $output.StartsWith($package.Directory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release output must be outside the authenticated package directory.'
    }
    Assert-WinAirPlayReleaseAncestors -Path $output
    $null = [IO.Directory]::CreateDirectory($output)
    $archiveName = "WinAirPlayAudio-$($version.Version)-windows-x64-$SigningState.zip"
    $archivePath = Join-Path $output $archiveName
    $checksumPath = "$archivePath.sha256"
    if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $checksumPath)) {
        throw 'Release output already exists; choose an empty output directory. Existing archives are never overwritten.'
    }
    $stage = Join-Path $output ('.bundle-stage-' + [Guid]::NewGuid().ToString('N'))
    $archiveOwned = $false
    $checksumOwned = $false
    try {
        $null = [IO.Directory]::CreateDirectory($stage)
        foreach ($relative in @(Get-WinAirPlayReleaseSourceFileNames)) {
            Copy-WinAirPlayReleaseFile -Source (Join-Path $root $relative) `
                -Destination (Join-Path $stage $relative)
        }
        foreach ($name in @(Get-WinAirPlayPackageFileNames)) {
            Copy-WinAirPlayReleaseFile -Source (Join-Path $package.Directory $name) `
                -Destination (Join-Path $stage "package/$name")
        }
        # Revalidate the copied payload rather than trusting a prior source check.
        $stagedPackage = Assert-WinAirPlayReleasePackage -PackageDirectory (Join-Path $stage 'package') `
            -RepositoryRoot $stage -VersionState $version -Configuration $Configuration -BuilderRoots $builderRoots `
        -SigningState $SigningState -ExpectedSignerThumbprint $ExpectedSignerThumbprint `
        -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256
        $packageManifestHash = (Get-FileHash -LiteralPath $stagedPackage.Manifest -Algorithm SHA256).Hash
        if ($SigningState -ceq 'test-signed') {
            foreach ($name in @(Get-WinAirPlayGuiFileNames -Version $version.Version)) {
                Copy-WinAirPlayReleaseFile -Source (Join-Path $GuiDirectory $name) -Destination (Join-Path $stage $name)
            }
            Assert-WinAirPlayReleaseGui -GuiDirectory $stage -VersionState $version -SourceCommit $sourceCommit[0] `
                -ExpectedSignedManifestSha256 $packageManifestHash -ExpectedSignerThumbprint $ExpectedSignerThumbprint -BuilderRoots $builderRoots -AllowOtherEntries
            # The authenticated outer ZIP anchors this generated launcher and its
            # expected package identities. Never derive trust from the package
            # at install time or require the user to transcribe developer hashes.
            $launcherPath = Join-Path $stage 'Setup.cmd'
            $launcherText = [IO.File]::ReadAllText($launcherPath)
            $launcherMarker = '-Pause %*'
            if ([regex]::Matches($launcherText, [regex]::Escape($launcherMarker)).Count -ne 1) {
                throw 'Setup launcher must contain exactly one parameter-insertion marker.'
            }
            $pinnedArguments = "-Pause -ExpectedSignedManifestSha256 $packageManifestHash -ExpectedSignerThumbprint $ExpectedSignerThumbprint %*"
            [IO.File]::WriteAllText($launcherPath, $launcherText.Replace($launcherMarker, $pinnedArguments),
                [Text.UTF8Encoding]::new($false))
            # Removal remains available without an intact package payload. Only
            # the public test identity is embedded for optional trust cleanup.
            $uninstallLauncherPath = Join-Path $stage 'Uninstall.cmd'
            $uninstallLauncherText = [IO.File]::ReadAllText($uninstallLauncherPath)
            if ([regex]::Matches($uninstallLauncherText, [regex]::Escape($launcherMarker)).Count -ne 1) {
                throw 'Uninstall launcher must contain exactly one parameter-insertion marker.'
            }
            $uninstallArguments = "-Pause -ExpectedSignerThumbprint $ExpectedSignerThumbprint %*"
            [IO.File]::WriteAllText($uninstallLauncherPath,
                $uninstallLauncherText.Replace($launcherMarker, $uninstallArguments),
                [Text.UTF8Encoding]::new($false))
        }
        $installText = @"
# Unsigned developer preview: explicit test-machine signing required

This archive contains product $($version.Version), driver $($version.DriverVersion),
and an unsigned $Configuration x64 payload under ``package/``. It is signing input,
not a ready-to-install signed driver. No boot, certificate, or installation action
runs when the archive is extracted. Windows 11 x64 24H2 or newer and PowerShell 7
are required. Physical playback, volume/mute, soak, Verifier, HLK, and production
signing remain subject to the recorded release gates; see ``docs/known-limitations.md``.
**Windows endpoint mute and volume do not control outgoing audio. Windows mute
cannot be relied on to silence the remote receiver. Use its own controls.**

Source provenance: $binaryProvenance
The package records source commit ``$($packageManifest.SourceCommit)`` and
dirty-source state ``$($packageManifest.SourceTreeDirty)``. Assembly checkout
commit and state are recorded separately in ``bundle-manifest.json``.

1. Obtain this archive's expected SHA-256 through a trusted release channel and
   compare it with ``Get-FileHash -Algorithm SHA256`` before extraction. A checksum
   received from the same untrusted source is not independent authentication.
   ``bundle-manifest.json`` records hashes for every included file.
2. Use only a disposable, recovery-ready test machine. Review
   ``installer/README.md`` and ``docs/build-and-install.md``. Boot-policy changes,
   machine certificate trust, reboot, signing and clean reinstall are separate,
   explicit operator actions. A clean reinstall deletes previous product config,
   credentials and logs. Neither this bundle nor its scripts disables Secure Boot.
3. Restore the exact signing tool packages from the bundle root. Download NuGet
   7.6.0 from ``https://dist.nuget.org/win-x86-commandline/v7.6.0/nuget.exe`` and
   require SHA-256 ``751EE5E79481626A428C1241DC7F94BCA2739B32588E669715BC5FB54D8FB8A2``
   before executing it. Then run:

``````powershell
.\nuget.exe restore .\driver\packages.config -PackagesDirectory .\driver\packages -NonInteractive
``````

The signing script independently verifies the complete pinned SDK/WDK tool
runtime inventories before elevated execution. No Rust, C++, or driver build is
needed to sign this existing payload.
The authenticated ``package/README.md`` and ``package/BUILD-AND-INSTALL.md`` are
unchanged source-reference snapshots retained in the signing-input payload;
follow this INSTALL.md and the bundle-root README for artifact-specific steps.

4. In an elevated PowerShell 7 terminal, explicitly prepare test signing and a
   dedicated certificate using the documented acknowledgement switches. If boot
   policy changes, reboot manually before proceeding. Once those prerequisites
   are independently confirmed, sign and install the verified payload:

``````powershell
`$expectedUnsignedManifestSha256 = '$packageManifestHash'
`$thumbprint = '<dedicated-test-certificate-40-hex-thumbprint>'
`$signed = .\installer\Sign-TestPackage.ps1 -PackageDirectory .\package ``
  -CertificateThumbprint `$thumbprint -ExpectedManifestSha256 `$expectedUnsignedManifestSha256
.\installer\Install-Driver.ps1 -PackageDirectory `$signed.PackageDirectory ``
  -ExpectedSignedManifestSha256 `$signed.SignedManifestSha256 -ExpectedSignerThumbprint `$thumbprint
``````

The embedded unsigned-manifest hash is trustworthy only after the archive has
been authenticated against the independent expected archive hash. Sign and
install scripts require elevation, ownership checks and explicit confirmation;
they do not make this preview production-signed. Uninstall and explicit test
certificate/boot-policy cleanup procedures are in ``installer/README.md``.
For an existing owned installation, ``Uninstall.cmd -Plan`` previews removal and
``Uninstall.cmd`` starts guided cleanup with separate public-trust and test-mode
exit choices. It does not require signing this developer input or an intact
package payload; see the installed-state identity and recovery rules in the
installer guide.
"@
        [IO.File]::WriteAllText((Join-Path $stage 'INSTALL.md'), $installText, [Text.UTF8Encoding]::new($false))
        if ($SigningState -ceq 'test-signed') {
            Copy-WinAirPlayReleaseFile -Source $PublicCertificatePath -Destination (Join-Path $stage 'test-signing.cer')
            $stagedCertificate = Get-WinAirPlayPublicTestCertificate `
                -Path (Join-Path $stage 'test-signing.cer') -ExpectedThumbprint $ExpectedSignerThumbprint
            $stagedCertificate.Dispose()
            $installText = @"
# Test-signed prerelease: isolated testing only

Product $($version.Version), driver $($version.DriverVersion), $Configuration x64.
The driver/service/tools are already test-signed. No Rust, Visual Studio, WDK,
NuGet, private key or local signing is needed. The guided setup targets Windows
11 x64 24H2+ and checks/provisions PowerShell 7 and the x64 VC++ v14 Runtime.
The native ``WinAirPlayAudio-$($version.Version)-Setup.exe`` and
``WinAirPlayAudio-$($version.Version)-Uninstall.exe`` wizards are also test-signed
by the pinned public identity. ``wizard-build.json`` records their final signed
hashes and the same signed-package/source anchors.

1. Authenticate this ZIP against an independently trusted release SHA-256 before
   extraction. Independently verify the public certificate's thumbprint:
   ``$ExpectedSignerThumbprint``. Never import a PFX/private key.
   After authenticating the ZIP, run ``Unblock-File -LiteralPath .\$archiveName``
   before extracting it so downloaded-file blocking does not prevent its scripts
   running. If already extracted, re-extract after unblocking the verified ZIP.
   Organization Group Policy still takes precedence; setup does not change machine
   execution policy. Never bypass your organization's policy.
2. Use a disposable test PC with recovery access. Review Secure Boot and BitLocker
   recovery first and back up existing product configuration, credentials and logs.
   From the extracted bundle root, inspect the read-only plan:

``````powershell
.\Setup.cmd -Plan
``````

   Start guided setup from the same folder:

``````powershell
.\Setup.cmd
``````

   Double-clicking ``Setup.cmd`` runs the same guided flow. The released launcher
   embeds signed-manifest SHA-256 ``$packageManifestHash`` and signer thumbprint
   ``$ExpectedSignerThumbprint``. Setup checks dependencies, requests elevation and explicit consent
   for machine changes, prepares test mode and public certificate trust, and calls
   the existing verified driver/service installer. It refuses unsupported hosts
   and does not install a driver until test mode is active in the current boot.
   If a prerequisite or boot-policy change requires a reboot, save work, reboot
   manually, then rerun the same setup command. Setup never reboots automatically
   or disables Secure Boot. Secure Boot changes, if required, must be handled
   manually with recovery access and the BitLocker recovery key available.

   For the native interface, run ``WinAirPlayAudio-$($version.Version)-Setup.exe``
   instead of Setup.cmd. It presents requirements, explicit change approvals,
   progress/errors and the same manual-restart/retry guidance. Keep its companion
   ``WinAirPlayAudio-$($version.Version)-Uninstall.exe`` outside the installed
   product directory for later independent removal. Test signatures are not
   Microsoft production certification.

The launcher's embedded manifest hash and signer are trustworthy only after the
release ZIP has been authenticated. Setup does not infer its expected identity
from the package it is about to trust. A clean reinstall permanently removes prior product
configuration, credentials and logs. See ``installer/README.md`` for setup options
and the dependency download/trust policy.

For manual preparation/recovery, in elevated PowerShell 7 explicitly enable test
mode, then reboot manually before certificate trust or installation:

``````powershell
.\installer\Set-TestSigning.ps1 -Mode Enable ``
  -AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk
``````

These scripts never disable Secure Boot or reboot automatically.
After reboot, in elevated PowerShell 7 explicitly trust the public certificate
and install:

``````powershell
`$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path .\test-signing.cer).Path)
if (`$certificate.Thumbprint -cne '$ExpectedSignerThumbprint') { throw 'Certificate mismatch' }
foreach (`$store in @('Root', 'TrustedPublisher')) {
  `$trusted = Import-Certificate -FilePath .\test-signing.cer -CertStoreLocation "Cert:\LocalMachine\`$store"
  `$trusted.FriendlyName = 'WinAirPlayAudio driver test signing'
}
.\installer\Install-Driver.ps1 -PackageDirectory .\package ``
  -ExpectedSignedManifestSha256 '$packageManifestHash' ``
  -ExpectedSignerThumbprint '$ExpectedSignerThumbprint'
Get-Service WinAirPlayAudioService
& "`$env:ProgramFiles\WinAirPlayAudio\endpoint-list.exe" --json
``````

This is a destructive clean reinstall, removing prior product configuration,
credentials and logs. It installs the driver, service and scoped firewall rule.
The manifest hash above is trusted only after authenticating the ZIP.
Package README/BUILD-AND-INSTALL files are immutable source snapshots; follow
this INSTALL.md for the already-signed artifact. Source: ``$($packageManifest.SourceCommit)``.

**Windows endpoint mute/volume does not control outgoing audio. Use receiver
controls.** Only experimental classic plaintext RAOP is implemented; AirPlay 2
is unsupported. Physical playback, clean-host, privilege, soak, Verifier/HLK and
production release gates remain open; see docs/known-limitations.md.

For native removal, run ``WinAirPlayAudio-$($version.Version)-Uninstall.exe``.
Alternatively inspect ``Uninstall.cmd -Plan``, then run ``Uninstall.cmd`` or double-click
it. Both interfaces request elevation and explicit removal consent,
removes the product service, firewall rule, devices/Driver Store packages,
runtime, configuration, credentials, logs and product snapshots, and verifies
cleanup before offering optional public-certificate cleanup and test-mode exit.
The uninstaller embeds signer thumbprint ``$ExpectedSignerThumbprint`` for optional
test-trust cleanup; it does not require an intact ``package/`` or its manifest.

Leaving test mode is a separate choice after successful removal. It requires
boot-change, BitLocker recovery and other-test-driver acknowledgements. Disabling
TESTSIGNING affects every test-signed driver on the machine. A selected boot-policy
change returns 3010: restart Windows manually, then restore Secure Boot as
appropriate. No automatic reboot or firmware change occurs. Shared PowerShell/VC++
runtimes and signing private keys are retained. See ``installer/README.md`` for
unattended flags and manual recovery using ``Uninstall-Driver.ps1``,
``Remove-TestCertificate.ps1`` and ``Set-TestSigning.ps1``. This driver requires
test mode while in use.
"@
            [IO.File]::WriteAllText((Join-Path $stage 'INSTALL.md'), $installText, [Text.UTF8Encoding]::new($false))
        }
        Update-WinAirPlayReleaseDocumentation -Stage $stage
        $readmeText = @"
# WinAirPlayAudio $($version.Version): unsigned developer preview

Start with [INSTALL.md](INSTALL.md). This archive contains the existing
$Configuration x64 signing-input payload in ``package/`` and bounded explicit
signing/install/uninstall tooling. It contains no buildable source checkout,
production-signed installer, or automatic boot/certificate changes.

**Windows endpoint mute and volume do not control outgoing audio. Windows mute
cannot be relied on to silence the remote receiver. Use its own controls.**

The prototype targets Windows 11 x64 24H2 or newer and classic plaintext
PCM/L16 RAOP. AirPlay 2 is not implemented. Physical output, corrected WLAN,
soak, minimum service privileges, Verifier/HLK and production signing remain
open gates; see [known limitations](docs/known-limitations.md) and
[the defect tracker](docs/DEFECTS.md). Read [SECURITY.md](SECURITY.md) before
handling private evidence or using privileged tooling.

Authenticate the ZIP against an independently trusted expected archive SHA-256
before extraction. ``bundle-manifest.json`` records the included file hashes;
the external ``.sha256`` file records the ZIP hash. Those hashes establish
integrity only when their expected values arrive through a trusted channel.

Source-reference documents carry a banner and label links requiring a complete
source checkout. The original source README is retained once inside the
immutable ``package/`` payload. Those authenticated documents are original
authenticated source-reference snapshots; INSTALL.md is the artifact procedure.

Original code outside the driver is [AGPL-3.0-only licensed](LICENSE);
the adapted driver retains its
[Microsoft Public License](driver/LICENSE.microsoft-samples.txt). See
[third-party notices](THIRD_PARTY_NOTICES.md).
Use ``Uninstall.cmd -Plan`` and ``Uninstall.cmd`` to inspect/remove an existing
owned product installation, with separate optional public-trust and test-mode
cleanup after verified removal. This does not make the unsigned payload ready
for installation.
"@
        if ($SigningState -ceq 'test-signed') {
            $readmeText = @"
# WinAirPlayAudio $($version.Version): test-signed prerelease

Start with [INSTALL.md](INSTALL.md). The complete driver/service/tools in
``package/`` are already test-signed. Only the public ``test-signing.cer`` is
included; no private key is distributed. Verify the release ZIP hash and
certificate thumbprint through a trusted channel.

Native [setup](WinAirPlayAudio-$($version.Version)-Setup.exe) and
[removal](WinAirPlayAudio-$($version.Version)-Uninstall.exe) wizards are included,
test-signed by the same pinned identity. ``wizard-build.json`` records their
final signed hashes, package manifest and source commit. Keep the companion
removal wizard outside the installed product directory. These attended wizards
reuse the same guarded backend and never reboot automatically.

Run ``Setup.cmd`` for guided dependency checks/provisioning, explicit test-mode
preparation, certificate trust and driver/service installation. Follow INSTALL.md
for the embedded manifest/signer identities and read-only ``-Plan`` option. Reboot
manually when requested, then rerun setup. This experimental Windows 11 x64 24H2+
build requires test mode, explicit certificate trust, PowerShell 7 and the x64
VC++ v14 Runtime. Setup never disables Secure Boot or reboots automatically.
Run ``Uninstall.cmd`` for guided product removal, optional public test-trust
cleanup and the separate choice to leave test mode after cleanup succeeds;
``Uninstall.cmd -Plan`` is read-only. Boot-policy changes require explicit
recovery/other-driver acknowledgements and a manual restart.
**Windows endpoint mute/volume does not control outgoing audio. Use receiver
controls.** AirPlay 2 is unsupported. Installed/hardware/privilege/soak and
production-signing gates remain open; see [limitations](docs/known-limitations.md)
and [defects](docs/DEFECTS.md). Original code outside the driver is
[AGPL-3.0-only licensed](LICENSE);
the adapted driver retains its [Microsoft license](driver/LICENSE.microsoft-samples.txt).
"@
        }
        [IO.File]::WriteAllText((Join-Path $stage 'README.md'), $readmeText, [Text.UTF8Encoding]::new($false))
        $payloadFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Sort-Object FullName)
        [int64]$bundleBytes = 0
        $manifestFiles = @($payloadFiles | ForEach-Object {
            $bundleBytes += $_.Length
            if ($_.Length -gt 32MB -or $bundleBytes -gt 160MB) { throw 'Release bundle exceeds its size bound.' }
            [pscustomobject][ordered]@{
                Name = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
                Length = $_.Length
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        })
        [pscustomobject][ordered]@{
            SchemaVersion = 1
            Version = $version.Version
            DriverVersion = $version.DriverVersion
            Configuration = $Configuration
            SigningState = $SigningState
            SourceCommit = $packageManifest.SourceCommit
            SourceTreeDirty = $packageManifest.SourceTreeDirty
            AssemblySourceCommit = $sourceCommit[0]
            AssemblySourceTreeDirty = ($status.Count -ne 0)
            BinarySourceProvenance = $binaryProvenance
            UnsignedPackageManifestSha256 = if ($SigningState -ceq 'test-signed') { $packageManifest.UnsignedManifestSha256 } else { $packageManifestHash }
            SignedPackageManifestSha256 = if ($SigningState -ceq 'test-signed') { $packageManifestHash } else { $null }
            SignerThumbprint = if ($SigningState -ceq 'test-signed') { $ExpectedSignerThumbprint } else { $null }
            Files = $manifestFiles
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'bundle-manifest.json') -Encoding utf8
        $zipStream = $null
        $zip = $null
        try {
            $zipStream = [IO.FileStream]::new($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $archiveOwned = $true
            $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
            foreach ($file in @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Sort-Object FullName)) {
                $entryName = [IO.Path]::GetRelativePath($stage, $file.FullName).Replace('\', '/')
                $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $inputStream = $null
                $entryStream = $null
                try {
                    $inputStream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    $entryStream = $entry.Open()
                    $inputStream.CopyTo($entryStream)
                }
                finally {
                    if ($entryStream) { $entryStream.Dispose() }
                    if ($inputStream) { $inputStream.Dispose() }
                }
            }
        }
        finally {
            if ($zip) { $zip.Dispose(); $zipStream = $null }
            if ($zipStream) { $zipStream.Dispose() }
        }
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        $checksumStream = [IO.FileStream]::new($checksumPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $checksumOwned = $true
        try {
            $checksumBytes = [Text.UTF8Encoding]::new($false).GetBytes("$archiveHash  $archiveName`n")
            $checksumStream.Write($checksumBytes, 0, $checksumBytes.Length)
        }
        finally { $checksumStream.Dispose() }
        Remove-WinAirPlayReleaseStage -Stage $stage -OutputDirectory $output
        return [pscustomobject]@{ Version = $version.Version; Archive = $archivePath; ChecksumFile = $checksumPath; ArchiveSha256 = $archiveHash }
    }
    catch {
        if ($checksumOwned -and (Test-Path -LiteralPath $checksumPath)) {
            Remove-WinAirPlayReleaseArtifact -Path $checksumPath -OutputDirectory $output `
                -ExpectedName "$archiveName.sha256"
        }
        if ($archiveOwned -and (Test-Path -LiteralPath $archivePath)) {
            Remove-WinAirPlayReleaseArtifact -Path $archivePath -OutputDirectory $output -ExpectedName $archiveName
        }
        Remove-WinAirPlayReleaseStage -Stage $stage -OutputDirectory $output
        throw
    }
}

Invoke-WinAirPlayReleaseBundle -Configuration $Configuration -OutputDirectory $OutputDirectory `
    -AllowDirty:$AllowDirty -RepositoryRoot $RepositoryRoot -PackageDirectory $PackageDirectory `
    -SigningState $SigningState -ExpectedSignerThumbprint $ExpectedSignerThumbprint `
    -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 -PublicCertificatePath $PublicCertificatePath -GuiDirectory $GuiDirectory
