[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$bundleScript = Join-Path $PSScriptRoot 'New-ReleaseBundle.ps1'
$scratchParent = Join-Path $repositoryRoot '.local\diagnostics\release-bundle-tests'
$scratch = Join-Path $scratchParent ([Guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
$passedCases = [Collections.Generic.List[string]]::new()
$notRun = [Collections.Generic.List[string]]::new()

function Assert-ReleaseFixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = @(& git -C $script:fixtureRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture Git command failed: $($Arguments -join ' '): $($output -join ' ')"
    }
}

function Update-FixturePackageManifest {
    $sourceCommit = @(& git -C $script:fixtureRoot rev-parse --verify HEAD)
    if ($LASTEXITCODE -ne 0 -or $sourceCommit.Count -ne 1 -or $sourceCommit[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Package fixture requires one committed source revision.'
    }
    $payload = @(Get-ChildItem -LiteralPath $script:fixturePackage -File |
        Where-Object Name -CNE 'package-manifest.json' | Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Length = $_.Length
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                SignatureStatus = 'NotSigned'
                SignerThumbprint = $null
            }
        })
    [pscustomobject]@{
        SchemaVersion = 1
        Configuration = 'Release'
        Platform = 'x64'
        GeneratedAtUtc = '2026-01-01T00:00:00Z'
        HardwareId = 'ROOT\WinAirPlayAudio'
        UserService = 'WinAirPlayAudioService'
        SourceCommit = $sourceCommit[0]
        SourceTreeDirty = $false
        Files = $payload
    } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $script:fixturePackage 'package-manifest.json') -Encoding utf8
}

function Restore-FixturePackage {
    foreach ($file in Get-ChildItem -LiteralPath $script:fixturePackage -Force) {
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to restore a fixture containing an unexpected directory or reparse point: $($file.Name)"
        }
        if (-not $script:baselinePackage.ContainsKey($file.Name)) {
            [IO.File]::Delete($file.FullName)
        }
    }
    foreach ($entry in $script:baselinePackage.GetEnumerator()) {
        [IO.File]::WriteAllBytes((Join-Path $script:fixturePackage $entry.Key), $entry.Value)
    }
}

function Assert-NoBundleScratch {
    param([string]$OutputDirectory)
    if (Test-Path -LiteralPath $OutputDirectory) {
        $stages = @(Get-ChildItem -LiteralPath $OutputDirectory -Force |
            Where-Object Name -Like '.bundle-stage-*')
        Assert-ReleaseFixture ($stages.Count -eq 0) 'Release assembly left a temporary stage directory.'
    }
}

function Invoke-BundleFailureCase {
    param([string]$Name, [scriptblock]$Action, [string]$ExpectedMessage, [string]$OutputDirectory)
    $rejected = $false
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            throw "$Name failed for the wrong reason: $($_.Exception.Message)"
        }
        $rejected = $true
    }
    Assert-ReleaseFixture $rejected "Release assembly accepted $Name."
    Assert-NoBundleScratch -OutputDirectory $OutputDirectory
    if (Test-Path -LiteralPath $OutputDirectory) {
        Assert-ReleaseFixture (@(Get-ChildItem -LiteralPath $OutputDirectory -File -Force).Count -eq 0) `
            "$Name published a partial archive or checksum."
    }
    $script:passedCases.Add($Name)
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $script:fixtureRoot = Join-Path $scratch 'repository'
    New-Item -ItemType Directory -Path $script:fixtureRoot -Force | Out-Null

    # Load function definitions only. The release entry point, version checker,
    # builds and host-mutating installer actions are never executed by loading.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $bundleScript, [ref]$tokens, [ref]$parseErrors)
    Assert-ReleaseFixture ($parseErrors.Count -eq 0) 'Release bundle script does not parse.'
    foreach ($function in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Parent -is [Management.Automation.Language.NamedBlockAst]
        }, $false))) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    Assert-ReleaseFixture ($null -ne (Get-Command Invoke-WinAirPlayReleaseBundle -ErrorAction SilentlyContinue)) `
        'Release bundle core function is absent.'

    Import-Module (Join-Path $PSScriptRoot 'ReleaseLayout.psm1') -Force
    $sourcePaths = @(Get-WinAirPlayReleaseSourceFileNames)
    foreach ($relative in @($sourcePaths + 'README.md' + 'scripts/Test-SourceHygiene.ps1' + '.gitignore')) {
        $source = Join-Path $repositoryRoot $relative
        Assert-ReleaseFixture (Test-Path -LiteralPath $source -PathType Leaf) "Required fixture source is absent: $relative"
        $destination = Join-Path $script:fixtureRoot $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }

    . (Join-Path $script:fixtureRoot 'installer/Common.ps1')
    $script:fixturePackage = Join-Path $script:fixtureRoot '.local/package'
    New-Item -ItemType Directory -Path $script:fixturePackage -Force | Out-Null
    foreach ($name in @(Get-WinAirPlayPackageFileNames | Where-Object { $_ -cne 'package-manifest.json' })) {
        $file = Join-Path $script:fixturePackage $name
        if ([IO.Path]::GetExtension($name) -cin @('.exe', '.sys')) {
            # Minimal AMD64 PE fixture. It proves PE architecture checks, not
            # executable behavior or Windows resource-generation correctness.
            $bytes = [byte[]]::new(128)
            $bytes[0] = 0x4D; $bytes[1] = 0x5A
            [BitConverter]::GetBytes([int]0x40).CopyTo($bytes, 0x3C)
            [BitConverter]::GetBytes([int]0x00004550).CopyTo($bytes, 0x40)
            [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 0x44)
            [IO.File]::WriteAllBytes($file, $bytes)
        }
        else { [IO.File]::WriteAllText($file, "sanitized release fixture: $name") }
    }
    @'
[Version]
Provider = %ProviderName%
DriverVer = 07/27/2026,0.1.0.2
[Strings]
ProviderName = "WinAirPlayAudio"
[Fixture]
ROOT\WinAirPlayAudio
AddService = WinAirPlayAudio
'@ | Set-Content -LiteralPath (Join-Path $script:fixturePackage 'WinAirPlayAudio.inf') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'version.json') `
        -Destination (Join-Path $script:fixturePackage 'version.json') -Force
    '{"inventory_format":"winairplay-cargo-dependency-inventory-v1","packages":[],"resolve":{"root":null,"nodes":[]}}' |
        Set-Content -LiteralPath (Join-Path $script:fixturePackage 'cargo-metadata.json') -Encoding utf8
    Invoke-FixtureGit -Arguments @('init', '--quiet')
    Invoke-FixtureGit -Arguments @('add', '--all')
    Invoke-FixtureGit -Arguments @('-c', 'user.name=Release fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '--quiet', '-m', 'sanitized release fixture')
    $packageTokens = $null
    $packageParseErrors = $null
    $packageAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot 'installer/package.ps1'), [ref]$packageTokens, [ref]$packageParseErrors)
    $sourceStateFunctions = @($packageAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-WinAirPlayPackageSourceState'
        }, $false))
    Assert-ReleaseFixture ($packageParseErrors.Count -eq 0 -and $sourceStateFunctions.Count -eq 1) `
        'Package provenance helper is absent or its script does not parse.'
    . ([scriptblock]::Create($sourceStateFunctions[0].Extent.Text))
    $cleanSourceState = Get-WinAirPlayPackageSourceState -RepositoryRoot $script:fixtureRoot
    Assert-ReleaseFixture ($cleanSourceState.SourceCommit -cmatch '^[0-9a-f]{40}$' -and
        $cleanSourceState.SourceTreeDirty -is [bool] -and -not $cleanSourceState.SourceTreeDirty) `
        'Actual package provenance helper did not capture clean committed fixture source.'
    $passedCases.Add('actual package Git provenance captures clean committed source')
    Update-FixturePackageManifest
    $script:baselinePackage = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal)
    foreach ($file in Get-ChildItem -LiteralPath $script:fixturePackage -File) {
        $script:baselinePackage.Add($file.Name, [IO.File]::ReadAllBytes($file.FullName))
    }

    # Only the canonical version, SYS resource and Authenticode readers are
    # mocked. Minimal synthetic PE/CAT files are not valid Windows signatures.
    # Separate version tests and a full real-package run cover those readers.
    function Get-WinAirPlayReleaseVersion {
        param([string]$RepositoryRoot)
        [pscustomobject]@{ Version = '0.1.0'; DriverVersion = '0.1.0.2'; DriverDate = '2026-07-27' }
    }
    $script:fixtureDriverVersion = '0.1.0.2'
    function Get-WinAirPlayReleaseDriverVersion {
        param([string]$Path)
        return $script:fixtureDriverVersion
    }

    $script:fixtureSignatureStatus = 'NotSigned'
    $script:fixtureSignatureCertificate = $null
    function Get-WinAirPlayReleaseAuthenticodeState {
        param([string]$Path)
        $fullPath = [IO.Path]::GetFullPath($Path)
        $fixturePrefix = [IO.Path]::GetFullPath($script:fixtureRoot).TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($fullPath) -notin @('.cat', '.sys', '.exe')) {
            throw 'Fixture Authenticode reader must not inspect a file outside its owned synthetic package.'
        }
        [pscustomobject]@{
            Status = $script:fixtureSignatureStatus
            SignerCertificate = $script:fixtureSignatureCertificate
        }
    }

    $goodOutput = Join-Path $script:fixtureRoot '.local/release-good'
    $result = Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
        -PackageDirectory $script:fixturePackage -OutputDirectory $goodOutput
    Assert-ReleaseFixture ($result.Version -ceq '0.1.0') 'Release result lost the canonical version.'
    Assert-ReleaseFixture ([IO.Path]::GetFileName($result.Archive) -ceq 'WinAirPlayAudio-0.1.0-windows-x64-unsigned.zip') `
        'Release archive naming contract changed.'
    Assert-ReleaseFixture (Test-Path -LiteralPath $result.ChecksumFile -PathType Leaf) 'Release checksum file is absent.'
    $archiveHash = (Get-FileHash -LiteralPath $result.Archive -Algorithm SHA256).Hash
    $checksumText = Get-Content -LiteralPath $result.ChecksumFile -Raw
    Assert-ReleaseFixture ($checksumText -match ('(?i)^' + $archiveHash + '\s+\*?' +
            [regex]::Escape([IO.Path]::GetFileName($result.Archive)) + '\s*$')) `
        'Release checksum does not identify the exact archive bytes and file name.'
    $archive = [IO.Compression.ZipFile]::OpenRead($result.Archive)
    try {
        $members = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object FullName)
        foreach ($member in @($sourcePaths + 'README.md' + 'INSTALL.md' + 'bundle-manifest.json')) {
            Assert-ReleaseFixture ($member.Replace('\', '/') -cin $members) "Release archive omitted $member."
        }
        foreach ($name in @(Get-WinAirPlayPackageFileNames)) {
            Assert-ReleaseFixture (('package/' + $name) -cin $members) "Release archive omitted authenticated package/$name."
        }
        $expectedMembers = @($sourcePaths + 'README.md' + 'INSTALL.md' + 'bundle-manifest.json' +
            @(Get-WinAirPlayPackageFileNames | ForEach-Object { 'package/' + $_ }) |
            ForEach-Object { $_.Replace('\', '/') } | Sort-Object)
        Assert-ReleaseFixture ([Linq.Enumerable]::SequenceEqual[string](
                [string[]]$expectedMembers, [string[]]@($members | Sort-Object))) `
            'Release archive does not contain exactly the reviewed source, handoff, and authenticated package members.'
        Assert-ReleaseFixture (@($members | Where-Object {
                $_ -match '(^|/)(?:\.local|\.diagnostics|\.git|target)/|\.(?:pdb|pcapng?|dmp|pfx|log)$'
            }).Count -eq 0) 'Release archive contains private/generated material.'
        foreach ($markdownEntry in @($archive.Entries | Where-Object {
                $_.FullName.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase) -and
                -not $_.FullName.StartsWith('package/', [StringComparison]::Ordinal)
            })) {
            $reader = [IO.StreamReader]::new($markdownEntry.Open())
            try { $markdownText = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
            if ($markdownEntry.FullName -ceq 'README.md') {
                Assert-ReleaseFixture ($markdownText -match '\[INSTALL\.md\]\(INSTALL\.md\)' -and
                    $markdownText -match '(?is)mute.*cannot be relied on to silence') `
                    'Artifact README lacks the artifact INSTALL entry point or explicit remote-mute limitation.'
            }
            foreach ($link in [regex]::Matches($markdownText,
                    '(?<!!)\[(?<label>[^\]\r\n]+)\]\((?<target><[^>\r\n]+>|[^)\s]+)(?:\s+"[^"]*")?\)')) {
                $target = $link.Groups['target'].Value.Trim('<', '>')
                if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:|^#') { continue }
                $targetPath = [Uri]::UnescapeDataString(($target -split '#', 2)[0]).Replace('\', '/')
                if ([string]::IsNullOrEmpty($targetPath)) { continue }
                $baseUri = [Uri]::new('https://bundle.invalid/' + $markdownEntry.FullName)
                $resolved = [Uri]::UnescapeDataString(([Uri]::new($baseUri, $targetPath)).AbsolutePath.TrimStart('/'))
                Assert-ReleaseFixture ($resolved -cin $members) `
                    "Broken artifact Markdown link: $($markdownEntry.FullName) -> $target. Source-only references must be labeled as plain source-checkout references."
            }
        }
        $manifestEntry = $archive.GetEntry('bundle-manifest.json')
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -Depth 100 }
        finally { $reader.Dispose() }
        $manifestProperties = @($manifest.PSObject.Properties.Name)
        $manifestFilesName = if ('Files' -cin $manifestProperties) { 'Files' } else { 'files' }
        $manifestFiles = @($manifest.$manifestFilesName)
        Assert-ReleaseFixture ($manifestFiles.Count -eq ($members.Count - 1)) `
            'Bundle manifest does not hash every non-manifest file.'
        foreach ($entry in $manifestFiles) {
            $entryProperties = @($entry.PSObject.Properties.Name)
            $path = if ('Path' -cin $entryProperties) { [string]$entry.Path } elseif ('Name' -cin $entryProperties) {
                [string]$entry.Name
            } else { [string]$entry.path }
            $expectedHash = if ('Sha256' -cin $entryProperties) { [string]$entry.Sha256 } else { [string]$entry.sha256 }
            $zipEntry = $archive.GetEntry($path.Replace('\', '/'))
            Assert-ReleaseFixture ($null -ne $zipEntry) "Bundle manifest references missing $path."
            $stream = $zipEntry.Open()
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $actualHash = [Convert]::ToHexString($hasher.ComputeHash($stream)) }
            finally { $hasher.Dispose(); $stream.Dispose() }
            Assert-ReleaseFixture ($actualHash -ieq $expectedHash) "Bundle manifest hash mismatch: $path"
        }
    }
    finally { $archive.Dispose() }
    Assert-NoBundleScratch -OutputDirectory $goodOutput
    $passedCases.Add('exact archive membership, manifest hashes, external checksum and stage cleanup')
    $passedCases.Add('artifact README handoff and nonpackage Markdown link resolution')

    $existingBytes = [IO.File]::ReadAllBytes($result.Archive)
    $overwriteRejected = $false
    try {
        $null = Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $goodOutput
    }
    catch {
        Assert-ReleaseFixture ($_.Exception.Message -match 'exist|overwrite') 'Existing-output rejection failed for the wrong reason.'
        $overwriteRejected = $true
    }
    Assert-ReleaseFixture $overwriteRejected 'Release assembly overwrote an existing archive.'
    Assert-ReleaseFixture ([Linq.Enumerable]::SequenceEqual[byte]($existingBytes, [IO.File]::ReadAllBytes($result.Archive))) `
        'Release assembly changed a previously published archive.'
    Assert-NoBundleScratch -OutputDirectory $goodOutput
    $passedCases.Add('no overwrite')

    $caseOutput = Join-Path $script:fixtureRoot '.local/release-negative'
    $catalogRenameTemporary = Join-Path $script:fixturePackage 'catalog-rename.tmp'
    [IO.File]::Move((Join-Path $script:fixturePackage 'WinAirPlayAudio.cat'), $catalogRenameTemporary)
    [IO.File]::Move($catalogRenameTemporary, (Join-Path $script:fixturePackage 'winairplayaudio.cat'))
    Update-FixturePackageManifest
    $lowerCatalogOutput = Join-Path $script:fixtureRoot '.local/release-lowercase-catalog'
    $lowerCatalogResult = Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
        -PackageDirectory $script:fixturePackage -OutputDirectory $lowerCatalogOutput
    $lowerCatalogArchive = [IO.Compression.ZipFile]::OpenRead($lowerCatalogResult.Archive)
    try {
        Assert-ReleaseFixture ($null -ne $lowerCatalogArchive.GetEntry('package/WinAirPlayAudio.cat') -and
            $null -eq $lowerCatalogArchive.GetEntry('package/winairplayaudio.cat')) `
            'A lowercase WDK catalog name was not accepted and archived under the canonical package name.'
    }
    finally { $lowerCatalogArchive.Dispose() }
    Assert-NoBundleScratch -OutputDirectory $lowerCatalogOutput
    $passedCases.Add('lowercase WDK catalog accepted with canonical ZIP name')
    Restore-FixturePackage

    foreach ($uppercaseSignedCase in @(
            [pscustomobject]@{ Original = 'WinAirPlayAudioService.exe'; Uppercase = 'WinAirPlayAudioService.EXE' },
            [pscustomobject]@{ Original = 'WinAirPlayAudio.cat'; Uppercase = 'WinAirPlayAudio.CAT' })) {
        $renameTemporary = Join-Path $script:fixturePackage 'extension-rename.tmp'
        [IO.File]::Move((Join-Path $script:fixturePackage $uppercaseSignedCase.Original), $renameTemporary)
        [IO.File]::Move($renameTemporary, (Join-Path $script:fixturePackage $uppercaseSignedCase.Uppercase))
        Update-FixturePackageManifest
        $uppercaseManifestPath = Join-Path $script:fixturePackage 'package-manifest.json'
        $uppercaseManifest = Get-Content -LiteralPath $uppercaseManifestPath -Raw | ConvertFrom-Json
        $uppercaseEntry = @($uppercaseManifest.Files |
            Where-Object Name -CEQ $uppercaseSignedCase.Uppercase)[0]
        $uppercaseEntry.SignatureStatus = 'Valid'
        $uppercaseEntry.SignerThumbprint = ('A' * 40)
        $uppercaseManifest | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $uppercaseManifestPath -Encoding utf8
        Invoke-BundleFailureCase -Name "signed uppercase extension $($uppercaseSignedCase.Uppercase)" `
            -ExpectedMessage 'signed|ambiguous|unsigned' -OutputDirectory $caseOutput -Action {
            Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
                -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
        }
        Restore-FixturePackage
    }

    $provenanceManifestPath = Join-Path $script:fixturePackage 'package-manifest.json'
    foreach ($provenanceCase in @(
            [pscustomobject]@{ Name = 'missing package source provenance'; Kind = 'missing'; AllowDirty = $false },
            [pscustomobject]@{ Name = 'invalid source commit with AllowDirty'; Kind = 'invalid'; AllowDirty = $true },
            [pscustomobject]@{ Name = 'nonboolean dirty provenance with AllowDirty'; Kind = 'invalid boolean'; AllowDirty = $true },
            [pscustomobject]@{ Name = 'older package source commit'; Kind = 'older'; AllowDirty = $false },
            [pscustomobject]@{ Name = 'dirty package source'; Kind = 'dirty'; AllowDirty = $false })) {
        $provenanceManifest = Get-Content -LiteralPath $provenanceManifestPath -Raw | ConvertFrom-Json
        switch ($provenanceCase.Kind) {
            'missing' { $provenanceManifest.PSObject.Properties.Remove('SourceCommit') }
            'invalid' { $provenanceManifest.SourceCommit = 'not-a-commit' }
            'invalid boolean' { $provenanceManifest.SourceTreeDirty = 'false' }
            'older' { $provenanceManifest.SourceCommit = ('b' * 40) }
            'dirty' { $provenanceManifest.SourceTreeDirty = $true }
        }
        $provenanceManifest | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $provenanceManifestPath -Encoding utf8
        Invoke-BundleFailureCase -Name $provenanceCase.Name -ExpectedMessage 'provenance|source|commit|dirty' `
            -OutputDirectory $caseOutput -Action {
            Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
                -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput -AllowDirty:$provenanceCase.AllowDirty
        }
        Restore-FixturePackage
    }
    $previewManifest = Get-Content -LiteralPath $provenanceManifestPath -Raw | ConvertFrom-Json
    $previewManifest.SourceCommit = ('b' * 40)
    $previewManifest.SourceTreeDirty = $true
    $previewManifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $provenanceManifestPath -Encoding utf8
    $provenanceOutput = Join-Path $script:fixtureRoot '.local/release-provenance-preview'
    $provenanceResult = Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
        -PackageDirectory $script:fixturePackage -OutputDirectory $provenanceOutput -AllowDirty
    $provenanceArchive = [IO.Compression.ZipFile]::OpenRead($provenanceResult.Archive)
    try {
        $reader = [IO.StreamReader]::new($provenanceArchive.GetEntry('bundle-manifest.json').Open())
        try { $recordedProvenance = $reader.ReadToEnd() | ConvertFrom-Json -Depth 100 }
        finally { $reader.Dispose() }
        $assemblyCommit = @(& git -C $script:fixtureRoot rev-parse --verify HEAD)[0]
        Assert-ReleaseFixture ($recordedProvenance.SourceCommit -ceq ('b' * 40) -and
            $recordedProvenance.SourceTreeDirty -is [bool] -and $recordedProvenance.SourceTreeDirty -and
            $recordedProvenance.AssemblySourceCommit -ceq $assemblyCommit -and
            $recordedProvenance.AssemblySourceTreeDirty -is [bool] -and
            -not $recordedProvenance.AssemblySourceTreeDirty -and
            $recordedProvenance.BinarySourceProvenance -match '(?i)unverified') `
            'AllowDirty preview lost package provenance, conflated it with assembly HEAD, or omitted its unverified status.'
    }
    finally { $provenanceArchive.Dispose() }
    Assert-NoBundleScratch -OutputDirectory $provenanceOutput
    $passedCases.Add('AllowDirty retains mismatched dirty package provenance separately from clean assembly source')
    Restore-FixturePackage

    [IO.File]::AppendAllText((Join-Path $script:fixturePackage 'WinAirPlayAudioService.exe'), 'tampered')
    Invoke-BundleFailureCase -Name 'package hash tampering' -ExpectedMessage 'hash mismatch' -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage
    $signedManifestPath = Join-Path $script:fixturePackage 'package-manifest.json'
    $signedManifest = Get-Content -LiteralPath $signedManifestPath -Raw | ConvertFrom-Json
    $signedEntry = @($signedManifest.Files | Where-Object Name -CEQ 'WinAirPlayAudioService.exe')[0]
    $signedEntry.SignatureStatus = 'Valid'
    $signedEntry.SignerThumbprint = ('A' * 40)
    $signedManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $signedManifestPath -Encoding utf8
    Invoke-BundleFailureCase -Name 'signed manifest mislabeled as unsigned input' -ExpectedMessage 'signed|ambiguous|unsigned' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage
    foreach ($actualSignatureCase in @('Valid', 'UnknownError')) {
        $script:fixtureSignatureStatus = $actualSignatureCase
        $script:fixtureSignatureCertificate = if ($actualSignatureCase -ceq 'Valid') {
            [pscustomobject]@{ Thumbprint = ('A' * 40) }
        } else { $null }
        Invoke-BundleFailureCase -Name "AuthentiCode reader state $actualSignatureCase rejected for unsigned input" `
            -ExpectedMessage 'signed|ambiguous|unsigned|signature' -OutputDirectory $caseOutput -Action {
            Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
                -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
        }
    }
    $script:fixtureSignatureStatus = 'NotSigned'
    $script:fixtureSignatureCertificate = $null
    foreach ($privateBinaryCase in @(
            [pscustomobject]@{ Name = 'UTF8 builder path in binary'; Encoding = [Text.Encoding]::UTF8; Root = $script:fixtureRoot },
            [pscustomobject]@{ Name = 'UTF16 profile path in binary'; Encoding = [Text.Encoding]::Unicode; Root = $env:USERPROFILE })) {
        Assert-ReleaseFixture (-not [string]::IsNullOrWhiteSpace($privateBinaryCase.Root)) `
            'Windows profile path is unavailable for the binary privacy regression.'
        $injectedBytes = $privateBinaryCase.Encoding.GetBytes([string]$privateBinaryCase.Root)
        $binaryStream = [IO.FileStream]::new(
            (Join-Path $script:fixturePackage 'WinAirPlayAudioService.exe'),
            [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $binaryStream.Write($injectedBytes, 0, $injectedBytes.Length) }
        finally { $binaryStream.Dispose() }
        Update-FixturePackageManifest
        Invoke-BundleFailureCase -Name $privateBinaryCase.Name -ExpectedMessage 'binary|builder|profile path' `
            -OutputDirectory $caseOutput -Action {
            Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
                -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
        }
        Restore-FixturePackage
    }
    [IO.File]::WriteAllText((Join-Path $script:fixturePackage 'extra.txt'), 'unexpected')
    Invoke-BundleFailureCase -Name 'unexpected package entry' -ExpectedMessage 'exact|unexpected|bounded file set' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage
    $versionDrift = Get-Content -LiteralPath (Join-Path $script:fixturePackage 'version.json') -Raw | ConvertFrom-Json
    $versionDrift.version = '0.1.1'
    $versionDrift | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:fixturePackage 'version.json') -Encoding utf8
    Update-FixturePackageManifest
    Invoke-BundleFailureCase -Name 'package canonical version drift' -ExpectedMessage 'version|canonical' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage
    $script:fixtureDriverVersion = '0.1.0.9'
    Invoke-BundleFailureCase -Name 'SYS driver version drift' -ExpectedMessage 'version|DriverVer' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    $script:fixtureDriverVersion = '0.1.0.2'
    $infPath = Join-Path $script:fixturePackage 'WinAirPlayAudio.inf'
    [IO.File]::WriteAllText($infPath, [IO.File]::ReadAllText($infPath).Replace('0.1.0.2', '0.1.0.3'))
    Update-FixturePackageManifest
    Invoke-BundleFailureCase -Name 'INF driver version drift' -ExpectedMessage 'version|DriverVer' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage
    '{"inventory_format":"winairplay-cargo-dependency-inventory-v1","manifest_path":"C:\\Private Builder\\repo\\Cargo.toml"}' |
        Set-Content -LiteralPath (Join-Path $script:fixturePackage 'cargo-metadata.json') -Encoding utf8
    Update-FixturePackageManifest
    Invoke-BundleFailureCase -Name 'local path in published metadata' -ExpectedMessage 'path|private|metadata|inventory' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    Restore-FixturePackage

    $readme = Join-Path $script:fixtureRoot 'README.md'
    $originalReadme = [IO.File]::ReadAllBytes($readme)
    [IO.File]::AppendAllText($readme, "`nlocal dirty fixture")
    $dirtySourceState = Get-WinAirPlayPackageSourceState -RepositoryRoot $script:fixtureRoot
    Assert-ReleaseFixture ($dirtySourceState.SourceCommit -ceq $cleanSourceState.SourceCommit -and
        $dirtySourceState.SourceTreeDirty -is [bool] -and $dirtySourceState.SourceTreeDirty) `
        'Actual package provenance helper did not capture uncommitted source changes.'
    $passedCases.Add('actual package Git provenance captures dirty source without changing its recorded commit')
    Invoke-BundleFailureCase -Name 'dirty source by default' -ExpectedMessage 'clean|dirty|working tree' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput
    }
    $dirtyOutput = Join-Path $script:fixtureRoot '.local/release-dirty'
    $dirtyResult = Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
        -PackageDirectory $script:fixturePackage -OutputDirectory $dirtyOutput -AllowDirty
    Assert-ReleaseFixture (Test-Path -LiteralPath $dirtyResult.Archive -PathType Leaf) '-AllowDirty did not permit a safe local preview.'
    Assert-NoBundleScratch -OutputDirectory $dirtyOutput
    $passedCases.Add('AllowDirty safe preview')
    [IO.File]::WriteAllBytes($readme, $originalReadme)

    $privateFile = Join-Path $script:fixtureRoot '.local/private-fixture.pcapng'
    [IO.File]::WriteAllText($privateFile, 'deliberately synthetic private-path fixture')
    Invoke-FixtureGit -Arguments @('add', '--force', '.local/private-fixture.pcapng')
    Invoke-BundleFailureCase -Name 'AllowDirty privacy bypass' -ExpectedMessage 'private|generated|source set|diagnostic' `
        -OutputDirectory $caseOutput -Action {
        Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
            -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput -AllowDirty
    }
    Invoke-FixtureGit -Arguments @('rm', '--cached', '--quiet', '--', '.local/private-fixture.pcapng')
    [IO.File]::Delete($privateFile)

    $docsDirectory = Join-Path $script:fixtureRoot 'docs'
    $docsTarget = Join-Path $script:fixtureRoot '.local/docs-junction-target'
    $junctionMade = $false
    try {
        [IO.Directory]::Move($docsDirectory, $docsTarget)
        try {
            New-Item -ItemType Junction -Path $docsDirectory -Target $docsTarget -ErrorAction Stop | Out-Null
            $junctionMade = $true
        }
        catch { $notRun.Add("Directory-junction regression unavailable: $($_.Exception.Message)") }
        if ($junctionMade) {
            Invoke-BundleFailureCase -Name 'source-directory reparse point' -ExpectedMessage 'reparse|unsafe' `
                -OutputDirectory $caseOutput -Action {
                Invoke-WinAirPlayReleaseBundle -Configuration Release -RepositoryRoot $script:fixtureRoot `
                    -PackageDirectory $script:fixturePackage -OutputDirectory $caseOutput -AllowDirty
            }
        }
    }
    finally {
        if ($junctionMade) { Remove-Item -LiteralPath $docsDirectory -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $docsTarget) { [IO.Directory]::Move($docsTarget, $docsDirectory) }
    }

    $cleanupOutput = Join-Path $script:fixtureRoot '.local/artifact-cleanup'
    New-Item -ItemType Directory -Path $cleanupOutput -Force | Out-Null
    $largeArtifact = Join-Path $cleanupOutput 'large-fixture.zip'
    $largeStream = [IO.FileStream]::new($largeArtifact, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $largeStream.SetLength(33MB) }
    finally { $largeStream.Dispose() }
    Assert-ReleaseFixture ((Get-Item -LiteralPath $largeArtifact).Length -gt 32MB) `
        'Artifact cleanup regression did not create a file above the input-file bound.'
    Remove-WinAirPlayReleaseArtifact -Path $largeArtifact -OutputDirectory $cleanupOutput -ExpectedName 'large-fixture.zip'
    Assert-ReleaseFixture (-not (Test-Path -LiteralPath $largeArtifact)) `
        'Owned-artifact cleanup incorrectly applies the 32 MiB input limit.'
    $passedCases.Add('owned output artifact above 32 MiB cleans up')

    $outsideArtifact = Join-Path $script:fixtureRoot '.local/outside-fixture.zip'
    [IO.File]::WriteAllText($outsideArtifact, 'must remain outside the owned output directory')
    $outsideHash = (Get-FileHash -LiteralPath $outsideArtifact -Algorithm SHA256).Hash
    $outsideRejected = $false
    try {
        Remove-WinAirPlayReleaseArtifact -Path $outsideArtifact -OutputDirectory $cleanupOutput `
            -ExpectedName 'outside-fixture.zip'
    }
    catch {
        Assert-ReleaseFixture ($_.Exception.Message -match 'Refusing|owned output|outside') `
            'Artifact cleanup rejected the out-of-output fixture for the wrong reason.'
        $outsideRejected = $true
    }
    Assert-ReleaseFixture ($outsideRejected -and (Test-Path -LiteralPath $outsideArtifact -PathType Leaf) -and
        (Get-FileHash -LiteralPath $outsideArtifact -Algorithm SHA256).Hash -ceq $outsideHash) `
        'Artifact cleanup changed a file outside the exact owned output path.'
    $passedCases.Add('out-of-output artifact cleanup is refused without mutation')

    # Real ephemeral public DER, but mocked PE signatures: these cases prove
    # assembly/trust-anchor behavior, not execution of SignTool or installation.
    Restore-FixturePackage
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    $certificate = $null
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=WinAirPlayAudio synthetic release fixture', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $oids = [Security.Cryptography.OidCollection]::new()
        $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
        $publicPath = Join-Path $script:fixtureRoot '.local/test-signing.cer'
        [IO.File]::WriteAllBytes($publicPath, $certificate.RawData)
        $pin = $certificate.Thumbprint
        $manifestPath = Join-Path $script:fixturePackage 'package-manifest.json'
        $unsignedHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $signedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($entry in $signedManifest.Files) {
            if ([IO.Path]::GetExtension($entry.Name) -in @('.cat', '.sys', '.exe')) {
                $entry.SignatureStatus = 'Valid'
                $entry.SignerThumbprint = $pin
            }
        }
        $signedManifest | Add-Member -NotePropertyName UnsignedManifestSha256 -NotePropertyValue $unsignedHash
        $signedManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $signedHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $script:fixtureSignatureStatus = 'Valid'
        $script:fixtureSignatureCertificate = $certificate
        $guiDirectory = Join-Path $script:fixtureRoot '.local/gui-signed'
        $null = [IO.Directory]::CreateDirectory($guiDirectory)
        $guiNames = @(Get-WinAirPlayGuiFileNames -Version '0.1.0' | Where-Object { $_ -cne 'wizard-build.json' })
        foreach ($name in $guiNames) {
            Copy-Item -LiteralPath (Join-Path $script:fixturePackage 'WinAirPlayAudioService.exe') -Destination (Join-Path $guiDirectory $name)
        }
        $guiManifest = [pscustomobject]@{
            SchemaVersion=1; Version='0.1.0'; SourceCommit=$signedManifest.SourceCommit; SigningState='test-signed'
            CompilerVersion='7.1.1'; PreviewOnly=$false; PreviewOutcome=$null
            PayloadManifestSha256=$signedHash; SignerThumbprint=$pin
            Files=@($guiNames | ForEach-Object {
                $file=Get-Item -LiteralPath (Join-Path $guiDirectory $_)
                [pscustomobject]@{Name=$_; Bytes=$file.Length; Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                    SignatureStatus='Valid'; SignerThumbprint=$pin}
            })
        }
        $guiManifestPath = Join-Path $guiDirectory 'wizard-build.json'
        $guiManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $guiManifestPath -Encoding utf8
        $baselineGuiManifest = [IO.File]::ReadAllBytes($guiManifestPath)
        $signedArguments = @{
            Configuration='Release'; RepositoryRoot=$script:fixtureRoot; PackageDirectory=$script:fixturePackage
            OutputDirectory=(Join-Path $script:fixtureRoot '.local/release-signed')
            SigningState='test-signed'; ExpectedSignerThumbprint=$pin
            ExpectedSignedManifestSha256=$signedHash; PublicCertificatePath=$publicPath; GuiDirectory=$guiDirectory
        }
        $signedBundle = Invoke-WinAirPlayReleaseBundle @signedArguments
        Assert-ReleaseFixture ([IO.Path]::GetFileName($signedBundle.Archive) -ceq 'WinAirPlayAudio-0.1.0-windows-x64-test-signed.zip') `
            'Signed and unsigned archive names are ambiguous.'
        Assert-ReleaseFixture ($signedBundle.ArchiveSha256 -ceq (Get-FileHash -LiteralPath $signedBundle.Archive -Algorithm SHA256).Hash) `
            'Signing-job output does not anchor the exact final ZIP.'
        $zip = [IO.Compression.ZipFile]::OpenRead($signedBundle.Archive)
        try {
            $reader = [IO.StreamReader]::new($zip.GetEntry('bundle-manifest.json').Open())
            try { $outer = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            Assert-ReleaseFixture ($outer.SigningState -ceq 'test-signed' -and $outer.SignerThumbprint -ceq $pin -and
                $outer.UnsignedPackageManifestSha256 -ceq $unsignedHash -and $outer.SignedPackageManifestSha256 -ceq $signedHash) `
                'Signed bundle lost its signer or distinct input/output manifest anchors.'
            Assert-ReleaseFixture ($null -ne $zip.GetEntry('test-signing.cer') -and
                @($zip.Entries | Where-Object FullName -Match '\.(pfx|key|pem|pvk)$').Count -eq 0) `
                'Signed bundle public-certificate handoff includes a private-key payload.'
            $reader = [IO.StreamReader]::new($zip.GetEntry('INSTALL.md').Open())
            try { $installText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            Assert-ReleaseFixture ($installText.Contains($pin) -and $installText.Contains($signedHash) -and
                $installText.Contains('already test-signed') -and -not $installText.Contains('nuget.exe restore')) `
                'Prebuilt signed installation still requires local signing or omits trusted identities.'
            $reader = [IO.StreamReader]::new($zip.GetEntry('Setup.cmd').Open())
            try { $launcher = $reader.ReadToEnd() } finally { $reader.Dispose() }
            Assert-ReleaseFixture ($launcher.Contains("-ExpectedSignedManifestSha256 $signedHash") -and
                $launcher.Contains("-ExpectedSignerThumbprint $pin") -and
                $launcher.Contains('%*') -and $installText.Contains('.\Setup.cmd -Plan')) `
                'Signed setup launcher lacks embedded verified identities or guided options.'
            $reader = [IO.StreamReader]::new($zip.GetEntry('Uninstall.cmd').Open())
            try { $uninstallLauncher = $reader.ReadToEnd() } finally { $reader.Dispose() }
            Assert-ReleaseFixture ($uninstallLauncher.Contains("-ExpectedSignerThumbprint $pin") -and
                -not $uninstallLauncher.Contains('-ExpectedSignedManifestSha256') -and
                $uninstallLauncher.Contains('%*') -and $installText.Contains('Uninstall.cmd -Plan') -and
                $installText.Contains('after successful removal') -and $installText.Contains('3010')) `
                'Signed uninstaller lacks its public identity, independent removal path or explicit boot-policy handoff.'
            foreach ($name in @($guiNames + 'wizard-build.json')) {
                Assert-ReleaseFixture ($null -ne $zip.GetEntry($name)) 'Signed release omitted a GUI executable or signed inventory.'
            }
        }
        finally { $zip.Dispose() }
        $passedCases.Add('test-signed assembly, exact final ZIP hash, public certificate and install handoff')

        $invalid = $signedArguments.Clone()
        $invalid.OutputDirectory = Join-Path $script:fixtureRoot '.local/signed-rejected'
        $invalid.AllowDirty = $true
        $invalid.GuiDirectory = $null
        Invoke-BundleFailureCase -Name 'missing signed GUI directory' -ExpectedMessage 'empty|null|requires.*GUI' `
            -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        $invalid.GuiDirectory = $guiDirectory
        foreach ($case in @('Preview', 'Unsigned', 'WrongPin', 'WrongPayload')) {
            try {
                $badGui = [Text.Encoding]::UTF8.GetString($baselineGuiManifest) | ConvertFrom-Json
                switch ($case) {
                    'Preview' { $badGui.PreviewOnly = $true }
                    'Unsigned' { $badGui.Files[0].SignatureStatus = 'NotSigned' }
                    'WrongPin' { $badGui.Files[0].SignerThumbprint = '0' * 40 }
                    'WrongPayload' { $badGui.PayloadManifestSha256 = '0' * 64 }
                }
                $badGui | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $guiManifestPath -Encoding utf8
                Invoke-BundleFailureCase -Name "invalid signed GUI $case" -ExpectedMessage 'GUI metadata|GUI inventory' `
                    -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
            } finally { [IO.File]::WriteAllBytes($guiManifestPath, $baselineGuiManifest) }
        }
        $extraGui = Join-Path $guiDirectory 'extra.exe'
        try {
            [IO.File]::WriteAllText($extraGui, 'synthetic unexpected payload')
            Invoke-BundleFailureCase -Name 'extra GUI executable' -ExpectedMessage 'exactly both wizard' `
                -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        } finally { Remove-Item -LiteralPath $extraGui -Force }
        $uninstallSource = Join-Path $script:fixtureRoot 'Uninstall.cmd'
        $uninstallSourceText = [IO.File]::ReadAllText($uninstallSource)
        try {
            [IO.File]::WriteAllText($uninstallSource, $uninstallSourceText.Replace('-Pause %*', '-Pause'))
            Invoke-BundleFailureCase -Name 'uninstall launcher missing pin insertion marker' -ExpectedMessage 'Uninstall launcher must contain exactly one' `
                -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
            [IO.File]::WriteAllText($uninstallSource, $uninstallSourceText + "`r`nrem -Pause %*`r`n")
            Invoke-BundleFailureCase -Name 'uninstall launcher duplicate pin insertion marker' -ExpectedMessage 'Uninstall launcher must contain exactly one' `
                -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        }
        finally { [IO.File]::WriteAllText($uninstallSource, $uninstallSourceText) }
        $invalid.ExpectedSignedManifestSha256 = '0' * 64
        Invoke-BundleFailureCase -Name 'wrong final signed manifest hash' -ExpectedMessage 'pinned signer|signed-manifest' `
            -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        $invalid.ExpectedSignedManifestSha256 = $signedHash
        $invalid.ExpectedSignerThumbprint = '0' * 40
        Invoke-BundleFailureCase -Name 'wrong public signing certificate' -ExpectedMessage 'expected identity' `
            -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        $invalid.ExpectedSignerThumbprint = $pin
        $script:fixtureSignatureStatus = 'NotSigned'
        Invoke-BundleFailureCase -Name 'declared signature without an actual signature' -ExpectedMessage 'unsigned, invalid|unexpected signer' `
            -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        $script:fixtureSignatureStatus = 'Valid'
        $invalid.SigningState = 'unsigned'
        Invoke-BundleFailureCase -Name 'unsigned label with signing inputs' -ExpectedMessage 'does not accept signing inputs' `
            -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }

        $publicOnly = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData)
        try { $script:substitutedCertificateBytes = $publicOnly.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12) }
        finally { $publicOnly.Dispose() }
        $script:copyImplementation = (Get-Command Copy-WinAirPlayReleaseFile).ScriptBlock
        try {
            function Copy-WinAirPlayReleaseFile {
                param([string]$Source, [string]$Destination)
                & $script:copyImplementation -Source $Source -Destination $Destination
                if ([IO.Path]::GetFileName($Destination) -ceq 'test-signing.cer') {
                    # A certificate-only PFX models source replacement without
                    # writing any actual private key to diagnostic fixtures.
                    [IO.File]::WriteAllBytes($Destination, $script:substitutedCertificateBytes)
                }
            }
            $invalid.SigningState = 'test-signed'
            Invoke-BundleFailureCase -Name 'public certificate changed to PFX during copy' -ExpectedMessage 'Only one public DER certificate' `
                -OutputDirectory $invalid.OutputDirectory -Action { Invoke-WinAirPlayReleaseBundle @invalid }
        }
        finally { Set-Item -LiteralPath Function:Copy-WinAirPlayReleaseFile -Value $script:copyImplementation }
    }
    finally {
        if ($certificate) { $certificate.Dispose() }
        $rsa.Dispose()
        $script:fixtureSignatureStatus = 'NotSigned'
        $script:fixtureSignatureCertificate = $null
        Restore-FixturePackage
    }
}
catch { $failures.Add($_.Exception.Message) }
finally {
    if (Test-Path -LiteralPath $scratch) {
        $resolvedScratch = [IO.Path]::GetFullPath((Get-Item -LiteralPath $scratch -Force).FullName)
        $resolvedParent = [IO.Path]::GetFullPath($scratchParent).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not $resolvedScratch.StartsWith($resolvedParent + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedScratch) -cnotmatch '^[0-9a-f]{32}$' -or
            ((Get-Item -LiteralPath $scratch -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing cleanup outside the owned release-test scratch directory.'
        }
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedScratch) { throw 'Release-test scratch cleanup left residue.' }
    }
}

foreach ($case in $passedCases) { Write-Host "PASS: $case" }
foreach ($case in $notRun) { Write-Host "NOT RUN: $case" }
if ($failures.Count -gt 0) { throw "Release bundle tests failed: $($failures -join '; ')" }
Write-Host 'Release bundle fixture tests passed. Canonical-version, SYS-resource and Authenticode readers were mocked; no build, signing, installation or hardware acceptance is implied.'
