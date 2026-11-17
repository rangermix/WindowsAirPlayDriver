[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'installer/Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseLayout.psm1') -Force
$parent = Join-Path $repo '.local/diagnostics/installer-release-tests'
$null = [IO.Directory]::CreateDirectory($parent)
$scratch = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$fixtureRepository = Join-Path $scratch 'repository'
$null = [IO.Directory]::CreateDirectory($fixtureRepository)
$version = '0.1.0'
$commit = '1' * 40
$cases = 0
$rsa = [Security.Cryptography.RSA]::Create(2048)
$certificate = $null

function Assert-InstallerFixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Import-FixtureFunctions([string]$Path, [string[]]$Names) {
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-InstallerFixture ($errors.Count -eq 0) "Fixture source does not parse: $Path"
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Parent -is [Management.Automation.Language.NamedBlockAst]
    }, $false))
    foreach ($name in $Names) {
        $match = @($definitions | Where-Object Name -CEQ $name)
        Assert-InstallerFixture ($match.Count -eq 1) "Required fixture function missing: $name"
        $definition = $match[0].Extent.Text -replace ('^function\s+' + [regex]::Escape($name)), "function script:$name"
        . ([scriptblock]::Create($definition))
    }
}
function Invoke-InstallerFixture($Fixture, [string]$Output) {
    return Invoke-WinAirPlayInstallerRelease -ArchivePath $Fixture.Archive -ChecksumPath $Fixture.Checksum `
        -OutputDirectory $Output -Version $version -SourceCommit $commit `
        -ExpectedSignerThumbprint $certificate.Thumbprint -RepositoryRoot $fixtureRepository
}
function Assert-InstallerFixtureClean([string]$Output) {
    if (Test-Path -LiteralPath $Output) {
        Assert-InstallerFixture (@(Get-ChildItem -LiteralPath $Output -Force).Count -eq 0) `
            'Failed installer producer left a partial archive, checksum or lock.'
    }
    $producerScratch = Join-Path $fixtureRepository '.local/diagnostics/installer-release'
    if (Test-Path -LiteralPath $producerScratch) {
        Assert-InstallerFixture (@(Get-ChildItem -LiteralPath $producerScratch -Force).Count -eq 0) `
            'Installer producer left scratch residue.'
    }
}
function Assert-InstallerRejected([string]$Name, [scriptblock]$Action, [string]$Output, [string]$Message='.') {
    $rejected=$false
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notmatch $Message) { throw "$Name failed for the wrong reason: $($_.Exception.Message)" }
        $rejected=$true
    }
    Assert-InstallerFixture $rejected "Installer producer accepted $Name."
    Assert-InstallerFixtureClean $Output
    $script:cases++
    Write-Host "PASS: $Name"
}

try {
    # Reuse only the existing sanitized full-bundle generator, without executing
    # its entry point, GitHub mocks or publication tests.
    Import-FixtureFunctions (Join-Path $PSScriptRoot 'Test-ReleaseArchive.ps1') @('Get-Bytes','Get-Digest','New-FixtureArchive')
    $producerFunctions = @('Assert-WinAirPlayInstallerReleaseNoLinks', 'Remove-WinAirPlayInstallerReleaseScratch',
        'Get-WinAirPlayInstallerReleaseSignature', 'Get-WinAirPlayInstallerReleaseFileVersion',
        'Assert-WinAirPlayInstallerReleaseWizard', 'Invoke-WinAirPlayInstallerRelease')
    Import-FixtureFunctions (Join-Path $PSScriptRoot 'New-InstallerRelease.ps1') $producerFunctions
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Sanitized installer-release fixture',
        $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    # Synthetic executable bytes do not carry Windows resources/signatures.
    # Mock only those two platform readers; actual archive validation, hashes,
    # copying, locks, exact-pair projection and cleanup execute normally.
    $script:signatureStatus = 'Valid'
    $script:signaturePin = $certificate.Thumbprint
    $script:resourceVersion = '0.1.0.2'
    $script:resourceDescription = 'WinAirPlayAudio Setup'
    $script:signatureReads = 0
    function Get-WinAirPlayInstallerReleaseSignature {
        param([string]$Path)
        $script:signatureReads++
        [pscustomobject]@{Status=$script:signatureStatus;SignerCertificate=[pscustomobject]@{Thumbprint=$script:signaturePin}}
    }
    function Get-WinAirPlayInstallerReleaseFileVersion {
        param([string]$Path)
        [pscustomobject]@{Version=$script:resourceVersion;Description=$script:resourceDescription}
    }
    $fixture = New-FixtureArchive -Name 'valid-input' -State test-signed
    $output = Join-Path $scratch 'valid-output'
    $result = Invoke-InstallerFixture $fixture $output
    $expanded = Expand-WinAirPlayInstallerArchive -ArchivePath $result.Archive -ChecksumPath $result.ChecksumFile `
        -Destination (Join-Path $scratch 'valid-expanded') -Version $version
    $names = @("WinAirPlayAudio-$version-Setup.exe", "WinAirPlayAudio-$version-Uninstall.exe")
    Assert-InstallerFixture (@(Get-ChildItem -LiteralPath $expanded -File).Count -eq 2) 'Final release is not exactly the GUI pair.'
    $zip = [IO.Compression.ZipFile]::OpenRead($fixture.Archive)
    try {
        foreach ($name in $names) {
            $stream = $zip.GetEntry($name).Open(); $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $sha.Dispose(); $stream.Dispose() }
            Assert-InstallerFixture ((Get-FileHash -LiteralPath (Join-Path $expanded $name) -Algorithm SHA256).Hash -ceq $hash) `
                'Projection changed an already-signed GUI executable.'
        }
    } finally { $zip.Dispose() }
    Assert-InstallerFixture ($script:signatureReads -eq 4) 'Both input and projected GUI signatures were not checked.'
    Assert-InstallerFixture ($result.ArchiveSha256 -ceq (Get-FileHash -LiteralPath $result.Archive -Algorithm SHA256).Hash) 'Result digest differs.'
    Assert-InstallerFixture (-not (Test-Path -LiteralPath (Join-Path $output '.installer-release.lock'))) 'Output lock survived success.'
    $cases++; Write-Host 'PASS: exact GUI pair, signed bytes, checksum, platform checks and cleanup'

    $fixture = New-FixtureArchive -Name 'missing-gui' -State test-signed -MutateBytes { param($p) $null=$p.Remove("WinAirPlayAudio-$version-Setup.exe") }
    $output = Join-Path $scratch 'missing-output'
    Assert-InstallerRejected 'missing GUI executable' { Invoke-InstallerFixture $fixture $output } $output 'unexpected file count'
    $fixture = New-FixtureArchive -Name 'extra-input' -State test-signed -ExtraEntry 'private.pfx'
    $output = Join-Path $scratch 'extra-output'
    Assert-InstallerRejected 'extra internal bundle entry' { Invoke-InstallerFixture $fixture $output } $output 'unexpected file count'
    $fixture = New-FixtureArchive -Name 'preview-input' -State test-signed -MutateGui { param($g) $g.PreviewOnly=$true }
    $output = Join-Path $scratch 'preview-output'
    Assert-InstallerRejected 'preview GUI manifest' { Invoke-InstallerFixture $fixture $output } $output 'preview identity'
    $fixture = New-FixtureArchive -Name 'corrupt-gui' -State test-signed -MutateBytes { param($p) $p["WinAirPlayAudio-$version-Setup.exe"]=Get-Bytes 'tampered' }
    $output = Join-Path $scratch 'corrupt-output'
    Assert-InstallerRejected 'GUI bytes disagree with signed inventory' { Invoke-InstallerFixture $fixture $output } $output 'inventory/hash mismatch'
    $fixture = New-FixtureArchive -Name 'unsigned-input' -State unsigned
    $output = Join-Path $scratch 'unsigned-output'
    Assert-InstallerRejected 'unsigned internal bundle' { Invoke-InstallerFixture $fixture $output } $output 'file contract'
    $fixture = New-FixtureArchive -Name 'wrong-source' -State test-signed -MutateOuter { param($m) $m.SourceCommit='3'*40 }
    $output = Join-Path $scratch 'wrong-source-output'
    Assert-InstallerRejected 'wrong source provenance' { Invoke-InstallerFixture $fixture $output } $output 'provenance/state'
    $fixture = New-FixtureArchive -Name 'valid-signature-input' -State test-signed
    foreach ($status in @('NotSigned','HashMismatch','NotTrusted')) {
        $script:signatureStatus=$status
        $output = Join-Path $scratch "signature-$status-output"
        Assert-InstallerRejected "actual GUI signature $status" { Invoke-InstallerFixture $fixture $output } $output 'valid signature'
    }
    $script:signatureStatus='Valid'
    $script:signaturePin='F'*40
    $output = Join-Path $scratch 'wrong-pin-output'
    Assert-InstallerRejected 'unexpected actual GUI signer' { Invoke-InstallerFixture $fixture $output } $output 'pinned signer'
    $script:signaturePin=$certificate.Thumbprint
    $script:resourceVersion='0.1.0.9'
    $output = Join-Path $scratch 'wrong-version-output'
    Assert-InstallerRejected 'actual GUI resource version mismatch' { Invoke-InstallerFixture $fixture $output } $output 'Windows version'
    $script:resourceVersion='0.1.0.2'
    $script:resourceDescription='WinAirPlayAudio Setup Preview'
    $output = Join-Path $scratch 'resource-preview-output'
    Assert-InstallerRejected 'actual GUI preview resource' { Invoke-InstallerFixture $fixture $output } $output 'preview identity'
    $script:resourceDescription='WinAirPlayAudio Setup'
    foreach ($target in @('archive','checksum')) {
        $output = Join-Path $scratch "existing-$target-output"
        $null = [IO.Directory]::CreateDirectory($output)
        $name="WinAirPlayAudio-$version-windows-x64-test-signed.zip" + $(if ($target -ceq 'checksum') {'.sha256'} else {''})
        $existing = Join-Path $output $name
        [IO.File]::WriteAllText($existing, 'preserved existing artifact')
        $before=(Get-FileHash -LiteralPath $existing).Hash
        $failed=$false
        try { $null=Invoke-InstallerFixture $fixture $output } catch { $failed=$_.Exception.Message -match 'output already exists' }
        Assert-InstallerFixture ($failed -and (Get-FileHash -LiteralPath $existing).Hash -ceq $before -and
            @(Get-ChildItem -LiteralPath $output -Force).Count -eq 1) 'Existing archive/checksum was changed or output leaked.'
        $cases++; Write-Host "PASS: preserve existing $target without overwrite"
    }
    $fixture = New-FixtureArchive -Name 'changed-after-extraction' -State test-signed
    $output = Join-Path $scratch 'changed-after-extraction-output'
    function Expand-WinAirPlayReleaseArchive {
        param($ArchivePath,$ChecksumPath,$Destination,$Version,$SourceCommit,$SigningState,$ExpectedSignerThumbprint)
        $result = ReleaseLayout\Expand-WinAirPlayReleaseArchive @PSBoundParameters
        $manifestPath = Join-Path $result 'bundle-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
        $guiName = "WinAirPlayAudio-$Version-Setup.exe"
        $guiPath = Join-Path $result $guiName
        [IO.File]::WriteAllText($guiPath, 'replaced before deny-write lock')
        $record = @($manifest.Files | Where-Object Name -CEQ $guiName)[0]
        $record.Length = (Get-Item -LiteralPath $guiPath).Length
        $record.Sha256 = (Get-FileHash -LiteralPath $guiPath -Algorithm SHA256).Hash
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        return $result
    }
    try {
        Assert-InstallerRejected 'extraction tree replacement cannot redefine authenticated bytes' `
            { Invoke-InstallerFixture $fixture $output } $output 'changed before its read lock'
    } finally { Remove-Item -LiteralPath Function:Expand-WinAirPlayReleaseArchive -ErrorAction Stop }
    $fixture = New-FixtureArchive -Name 'final-reader-failure' -State test-signed
    $output = (Join-Path $scratch 'final-reader-failure-output') + [IO.Path]::DirectorySeparatorChar
    $script:installerReaderCalls=0
    function Expand-WinAirPlayInstallerArchive {
        param($ArchivePath,$ChecksumPath,$Destination,$Version)
        $script:installerReaderCalls++
        if ($script:installerReaderCalls -eq 2) { throw 'Injected final delivered-output verification failure.' }
        return ReleaseLayout\Expand-WinAirPlayInstallerArchive @PSBoundParameters
    }
    try {
        Assert-InstallerRejected 'final-output failure rolls back both files with a trailing output separator' `
            { Invoke-InstallerFixture $fixture $output } $output 'Injected final delivered-output'
    } finally { Remove-Item -LiteralPath Function:Expand-WinAirPlayInstallerArchive -ErrorAction Stop }
    $producerScratch=Join-Path $fixtureRepository '.local/diagnostics/installer-release'
    Assert-InstallerFixture (@(Get-ChildItem -LiteralPath $producerScratch -Force).Count -eq 0) 'Final producer scratch cleanup left residue.'
    Write-Host "Installer-only producer checks passed ($cases cases). Platform readers are mocked; no signing, trust or executable invocation occurred."
}
finally {
    if ($certificate) { $certificate.Dispose() }
    $rsa.Dispose()
    $full=[IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($full) -cne [IO.Path]::GetFullPath($parent) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') { throw 'Refusing installer fixture cleanup outside owned scope.' }
    if (Test-Path -LiteralPath $full) {
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing fixture cleanup containing reparse points.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $full) { throw 'Installer fixture cleanup left residue.' }
    }
}
