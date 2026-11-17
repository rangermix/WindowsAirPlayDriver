[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$previousExitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$hadExitVariable = $null -ne $previousExitVariable
$previousExitCode = if ($hadExitVariable) { $previousExitVariable.Value } else { $null }
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'installer/Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseLayout.psm1') -Force
$parent = Join-Path $repo '.local/diagnostics/release-archive-tests'
$null = [IO.Directory]::CreateDirectory($parent)
$scratch = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$version = '0.1.0'
$commit = '1' * 40
$cases = 0
$installedGh = $false
$rsa = [Security.Cryptography.RSA]::Create(3072)
$certificate = $null

function Assert-Fixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-Bytes([object]$Value) {
    return ,([Text.UTF8Encoding]::new($false).GetBytes([string]$Value))
}
function Get-Digest([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function New-FixtureArchive {
    param([string]$Name, [string]$State='unsigned', [scriptblock]$MutatePackage,
        [scriptblock]$MutateOuter, [scriptblock]$MutateBytes, [scriptblock]$BeforeInventory,
        [scriptblock]$MutateGui, [string]$ExtraEntry,
        [string]$DuplicateEntry, [string]$OversizedEntry)
    $directory = Join-Path $scratch $Name
    $null = [IO.Directory]::CreateDirectory($directory)
    $payload = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
    $sources = @(Get-WinAirPlayReleaseSourceFileNames)
    $packageNames = @(Get-WinAirPlayPackageFileNames)
    foreach ($path in @($sources + 'README.md' + 'INSTALL.md')) {
        $payload[$path] = Get-Bytes "Synthetic public fixture: $path"
    }
    foreach ($path in @($packageNames | Where-Object { $_ -cne 'package-manifest.json' })) {
        $payload["package/$path"] = Get-Bytes "Synthetic package fixture: $path"
    }
    $versionText = [ordered]@{schema_version=1; version=$version; driver_revision=2; driver_date='2026-07-27'} | ConvertTo-Json
    $payload['version.json'] = Get-Bytes $versionText
    $payload['package/version.json'] = Get-Bytes $versionText
    $payload['package/WinAirPlayAudio.inf'] = Get-Bytes "[Version]`nProvider = %ProviderName%`nDriverVer = 07/27/2026,0.1.0.2`n[Strings]`nProviderName = `"WinAirPlayAudio`"`n[Fixture]`nROOT\WinAirPlayAudio`nAddService = WinAirPlayAudio`n"
    $payload['package/cargo-metadata.json'] = Get-Bytes '{"inventory_format":"winairplay-cargo-dependency-inventory-v1","packages":[],"resolve":{"root":null,"nodes":[]}}'
    if ($State -ceq 'test-signed') { $payload['test-signing.cer'] = $certificate.RawData }
    $packageFiles = @($packageNames | Where-Object { $_ -cne 'package-manifest.json' } | ForEach-Object {
        $binary = [IO.Path]::GetExtension($_) -in @('.cat','.sys','.exe')
        [pscustomobject]@{ Name=$_; Length=$payload["package/$_"].Length; Sha256=(Get-Digest $payload["package/$_"])
            SignatureStatus=$(if ($State -ceq 'test-signed' -and $binary) {'Valid'} else {'NotSigned'})
            SignerThumbprint=$(if ($State -ceq 'test-signed' -and $binary) {$certificate.Thumbprint} else {$null}) }
    })
    $package = [pscustomobject]@{SchemaVersion=1; Configuration='Release'; Platform='x64'; HardwareId='ROOT\WinAirPlayAudio'
        UserService='WinAirPlayAudioService'; SourceCommit=$commit; SourceTreeDirty=$false; Files=$packageFiles}
    if ($State -ceq 'test-signed') { $package | Add-Member UnsignedManifestSha256 ('2' * 64) }
    if ($MutatePackage) { & $MutatePackage $package }
    $payload['package/package-manifest.json'] = Get-Bytes ($package | ConvertTo-Json -Depth 12)
    $packageHash = Get-Digest $payload['package/package-manifest.json']
    if ($State -ceq 'test-signed') {
        $guiNames = @("WinAirPlayAudio-$version-Setup.exe", "WinAirPlayAudio-$version-Uninstall.exe")
        foreach ($name in $guiNames) { $payload[$name] = Get-Bytes "Synthetic signed GUI fixture: $name" }
        $gui = [pscustomobject]@{
            SchemaVersion = 1; Version = $version; SourceCommit = $commit; SigningState = 'test-signed'
            CompilerVersion = '7.1.1'; PreviewOnly = $false; PreviewOutcome = $null
            PayloadManifestSha256 = $packageHash; SignerThumbprint = $certificate.Thumbprint
            GeneratedAtUtc = '2026-01-01T00:00:00Z'
            Files = @($guiNames | ForEach-Object {
                [pscustomobject]@{ Name = $_; Bytes = $payload[$_].Length; Sha256 = (Get-Digest $payload[$_])
                    SignatureStatus = 'Valid'; SignerThumbprint = $certificate.Thumbprint }
            })
        }
        if ($MutateGui) { & $MutateGui $gui }
        $payload['wizard-build.json'] = Get-Bytes ($gui | ConvertTo-Json -Depth 12)
    }
    if ($BeforeInventory) { & $BeforeInventory $payload }
    $outer = [pscustomobject]@{SchemaVersion=1; Version=$version; DriverVersion='0.1.0.2'; Configuration='Release'
        SigningState=$State; SourceCommit=$commit; SourceTreeDirty=$false; AssemblySourceCommit=$commit
        AssemblySourceTreeDirty=$false; BinarySourceProvenance='Synthetic structural fixture'
        UnsignedPackageManifestSha256=$(if ($State -ceq 'test-signed') {'2' * 64} else {$packageHash})
        SignedPackageManifestSha256=$(if ($State -ceq 'test-signed') {$packageHash} else {$null})
        SignerThumbprint=$(if ($State -ceq 'test-signed') {$certificate.Thumbprint} else {$null})
        Files=@($payload.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{Name=$_; Length=$payload[$_].Length; Sha256=(Get-Digest $payload[$_])} }) }
    if ($MutateOuter) { & $MutateOuter $outer }
    $payload['bundle-manifest.json'] = Get-Bytes ($outer | ConvertTo-Json -Depth 16)
    if ($MutateBytes) { & $MutateBytes $payload }
    $archivePath = Join-Path $directory "WinAirPlayAudio-$version-windows-x64-$State.zip"
    $zip = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($path in $payload.Keys) {
            $stream = $zip.CreateEntry($path).Open()
            try {
                if ($path -ceq $OversizedEntry) {
                    $buffer = [byte[]]::new(1MB)
                    for ($i=0; $i -lt 33; $i++) { $stream.Write($buffer,0,$buffer.Length) }
                } else { $stream.Write($payload[$path],0,$payload[$path].Length) }
            } finally { $stream.Dispose() }
        }
        foreach ($path in @($ExtraEntry,$DuplicateEntry) | Where-Object { $_ }) {
            $stream = $zip.CreateEntry($path).Open()
            try { $stream.WriteByte(1) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText("$archivePath.sha256", "$hash  $([IO.Path]::GetFileName($archivePath))`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Directory=$directory; Archive=$archivePath; Checksum="$archivePath.sha256"; Hash=$hash; State=$State}
}
function Invoke-ExpandFixture($Fixture, [string]$Pin=$certificate.Thumbprint) {
    $arguments = @{ArchivePath=$Fixture.Archive; ChecksumPath=$Fixture.Checksum; Destination=(Join-Path $Fixture.Directory 'expanded')
        Version=$version; SourceCommit=$commit; SigningState=$Fixture.State}
    if ($Fixture.State -ceq 'test-signed') { $arguments.ExpectedSignerThumbprint=$Pin }
    $null = Expand-WinAirPlayReleaseArchive @arguments
}
function New-InstallerFixtureArchive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$EntryNames = @("WinAirPlayAudio-$version-Setup.exe", "WinAirPlayAudio-$version-Uninstall.exe"),
        [string]$EmptyEntry,
        [string]$OversizedEntry,
        [string]$AttributeEntry,
        [int]$Attributes = 0,
        [switch]$CorruptPayload
    )
    $directory = Join-Path $scratch $Name
    $null = [IO.Directory]::CreateDirectory($directory)
    $archivePath = Join-Path $directory "WinAirPlayAudio-$version-windows-x64-test-signed.zip"
    $zip = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $EntryNames) {
            $entry = $zip.CreateEntry($name)
            if ($name -ceq $AttributeEntry) { $entry.ExternalAttributes = $Attributes }
            $stream = $entry.Open()
            try {
                if ($name -ceq $OversizedEntry) {
                    $buffer = [byte[]]::new(1MB)
                    for ($index = 0; $index -lt 33; $index++) { $stream.Write($buffer, 0, $buffer.Length) }
                } elseif ($name -cne $EmptyEntry) {
                    $bytes = Get-Bytes "Synthetic GUI envelope fixture: $name"
                    $stream.Write($bytes, 0, $bytes.Length)
                }
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    if ($CorruptPayload) {
        # Break the second local deflate stream while retaining a readable ZIP
        # directory and a correct outer checksum. Extraction must remove the
        # first output as well as the partially created second output.
        $bytes = [IO.File]::ReadAllBytes($archivePath)
        $entryName = $EntryNames[1]
        $nameBytes = [Text.Encoding]::UTF8.GetBytes($entryName)
        $latinText = [Text.Encoding]::Latin1.GetString($bytes)
        $localName = $latinText.IndexOf($entryName, [StringComparison]::Ordinal)
        if ($localName -lt 30 -or [BitConverter]::ToUInt32($bytes, $localName - 30) -ne 0x04034B50 -or
            [BitConverter]::ToUInt16($bytes, $localName - 22) -ne 8) {
            throw 'Corrupt-payload fixture could not locate its local deflate header.'
        }
        $extraLength = [BitConverter]::ToUInt16($bytes, $localName - 2)
        $payloadOffset = $localName + $nameBytes.Length + $extraLength
        $bytes[$payloadOffset] = 0xFF # Reserved deflate block type.
        [IO.File]::WriteAllBytes($archivePath, $bytes)
    }
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText("$archivePath.sha256", "$hash  $([IO.Path]::GetFileName($archivePath))`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Directory = $directory; Archive = $archivePath; Checksum = "$archivePath.sha256"; Hash = $hash }
}
function Invoke-ExpandInstallerFixture($Fixture) {
    $null = Expand-WinAirPlayInstallerArchive -ArchivePath $Fixture.Archive -ChecksumPath $Fixture.Checksum `
        -Destination (Join-Path $Fixture.Directory 'expanded') -Version $version
}
function Assert-Rejected([string]$Name, [scriptblock]$Action, [string]$Destination) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Fixture $rejected "Accepted invalid case: $Name"
    if ($Destination) { Assert-Fixture (-not (Test-Path -LiteralPath $Destination)) "Failed case left extraction output: $Name" }
    $script:cases++
    Write-Host "PASS: $Name"
}

try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=WinAirPlayAudio archive fixture', $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids = [Security.Cryptography.OidCollection]::new()
    $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays(1))
    foreach ($state in @('unsigned','test-signed')) {
        $fixture = New-FixtureArchive -Name "good-$state" -State $state
        Invoke-ExpandFixture $fixture
        Assert-Fixture (Test-Path -LiteralPath (Join-Path $fixture.Directory 'expanded/package/WinAirPlayAudio.sys')) 'Good archive did not extract complete package.'
        $cases++
        Write-Host "PASS: exact $state envelope"
        $caseFixture = New-FixtureArchive -Name "lowercase-catalog-$state" -State $state -MutatePackage {
            param($m) ($m.Files | Where-Object Name -IEQ 'WinAirPlayAudio.cat').Name='winairplayaudio.cat'
        }
        Invoke-ExpandFixture $caseFixture
        Assert-Fixture (Test-Path -LiteralPath (Join-Path $caseFixture.Directory 'expanded/package/WinAirPlayAudio.cat')) `
            'Windows catalog casing failed to resolve to the canonical archive member.'
        $cases++
        Write-Host "PASS: lowercase Windows catalog manifest in $state envelope"
    }
    foreach ($extra in @('../outside.txt','private.pfx','README.md')) {
        $fixture = New-FixtureArchive -Name ('extra-' + [Guid]::NewGuid().ToString('N')) -ExtraEntry $extra `
            -MutateBytes { param($p) $null=$p.Remove('INSTALL.md') }
        Assert-Rejected "unsafe/extra/duplicate entry $extra" { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    }
    $fixture = New-FixtureArchive -Name 'noncanonical-zip-catalog' -BeforeInventory {
        param($p)
        $p['package/winairplayaudio.cat']=$p['package/WinAirPlayAudio.cat']
        $null=$p.Remove('package/WinAirPlayAudio.cat')
    }
    Assert-Rejected 'noncanonical lowercase ZIP member with valid outer inventory' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'oversize' -OversizedEntry 'README.md'
    Assert-Rejected 'expanded entry exceeds 32 MiB' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'changed-content' -MutateBytes { param($p) $p['README.md']=Get-Bytes 'changed after hashing' }
    Assert-Rejected 'outer payload hash mismatch' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'outer-source' -MutateOuter { param($m) $m.SourceCommit='3' * 40 }
    Assert-Rejected 'outer source commit mismatch' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'inner-source' -MutatePackage { param($m) $m.SourceCommit='3' * 40 }
    Assert-Rejected 'inner source commit mismatch' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'inner-hash' -MutatePackage { param($m) $m.Files[0].Sha256='0' * 64 }
    Assert-Rejected 'inner hash mismatch with valid outer inventory' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'inner-duplicate' -MutatePackage { param($m) $m.Files[1].Name=$m.Files[0].Name }
    Assert-Rejected 'duplicate inner manifest payload' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'inner-duplicate-case' -MutatePackage { param($m) $m.Files[1].Name=$m.Files[0].Name.ToUpperInvariant() }
    Assert-Rejected 'case-variant duplicate inner manifest payload' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'wrong-declared-signature' -State test-signed -MutatePackage {
        param($m) $entry=$m.Files | Where-Object Name -CEQ 'WinAirPlayAudio.sys'; $entry.SignatureStatus='NotSigned'; $entry.SignerThumbprint=$null
    }
    Assert-Rejected 'mixed declared signed/unsigned payload' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'wrong-pin' -State test-signed
    Assert-Rejected 'public certificate signer pin mismatch' { Invoke-ExpandFixture $fixture ('0' * 40) } (Join-Path $fixture.Directory 'expanded')
    foreach ($name in @("WinAirPlayAudio-$version-Setup.exe", "WinAirPlayAudio-$version-Uninstall.exe", 'wizard-build.json')) {
        $script:removedGuiName = $name
        $fixture = New-FixtureArchive -Name ('missing-gui-' + [Guid]::NewGuid().ToString('N')) -State test-signed -BeforeInventory {
            param($p) $null = $p.Remove($script:removedGuiName)
        }
        Assert-Rejected "missing signed GUI member $name" { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    }
    $fixture = New-FixtureArchive -Name 'gui-changed-content' -State test-signed -BeforeInventory {
        param($p) $p["WinAirPlayAudio-$version-Setup.exe"] = Get-Bytes 'Changed after signed GUI inventory'
    }
    Assert-Rejected 'GUI hash mismatch with valid outer inventory' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $guiCases = @(
        @{ Name = 'GUI source commit mismatch'; Mutate = { param($m) $m.SourceCommit = '3' * 40 } },
        @{ Name = 'GUI signed payload anchor mismatch'; Mutate = { param($m) $m.PayloadManifestSha256 = '0' * 64 } },
        @{ Name = 'GUI metadata signer mismatch'; Mutate = { param($m) $m.SignerThumbprint = '0' * 40 } },
        @{ Name = 'GUI preview substituted for real wizard'; Mutate = { param($m) $m.PreviewOnly = $true } },
        @{ Name = 'GUI nonboolean preview state'; Mutate = { param($m) $m.PreviewOnly = 'false' } },
        @{ Name = 'unsigned GUI signature metadata'; Mutate = { param($m) $m.Files[0].SignatureStatus = 'NotSigned' } },
        @{ Name = 'GUI executable signer mismatch'; Mutate = { param($m) $m.Files[0].SignerThumbprint = '0' * 40 } },
        @{ Name = 'duplicate GUI inventory member'; Mutate = { param($m) $m.Files[1].Name = $m.Files[0].Name } },
        @{ Name = 'GUI length mismatch'; Mutate = { param($m) $m.Files[0].Bytes = $m.Files[0].Bytes + 1 } }
    )
    foreach ($case in $guiCases) {
        $fixture = New-FixtureArchive -Name ('invalid-gui-' + [Guid]::NewGuid().ToString('N')) -State test-signed -MutateGui $case.Mutate
        Assert-Rejected $case.Name { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    }
    $fixture = New-FixtureArchive -Name 'extra-gui-preview' -State test-signed -BeforeInventory {
        param($p) $p["WinAirPlayAudio-$version-Setup-Preview.exe"] = Get-Bytes 'Unexpected GUI preview'
    }
    Assert-Rejected 'unexpected GUI preview executable' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-FixtureArchive -Name 'wrong-checksum'
    [IO.File]::WriteAllText($fixture.Checksum, "$('0' * 64)  $([IO.Path]::GetFileName($fixture.Archive))`n")
    Assert-Rejected 'external archive checksum mismatch' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $publicOnly = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData)
    try { $script:certificateOnlyPfx = $publicOnly.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12) }
    finally { $publicOnly.Dispose() }
    $fixture = New-FixtureArchive -Name 'certificate-pfx' -State test-signed -BeforeInventory { param($p) $p['test-signing.cer']=$script:certificateOnlyPfx }
    Assert-Rejected 'PKCS12 substitution for public DER' { Invoke-ExpandFixture $fixture } (Join-Path $fixture.Directory 'expanded')

    $installerNames = @("WinAirPlayAudio-$version-Setup.exe", "WinAirPlayAudio-$version-Uninstall.exe")
    $fixture = New-InstallerFixtureArchive -Name 'installer-good'
    Invoke-ExpandInstallerFixture $fixture
    $expanded = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Directory 'expanded') -File)
    Assert-Fixture ($expanded.Count -eq 2 -and @($expanded | Where-Object Name -CNotIn $installerNames).Count -eq 0) `
        'Installer archive did not extract exactly the two versioned executables.'
    $cases++
    Write-Host 'PASS: exact public installer/uninstaller envelope'
    foreach ($entries in @(
        @{ Name = 'missing Setup'; Names = @($installerNames[1]) },
        @{ Name = 'missing Uninstall'; Names = @($installerNames[0]) },
        @{ Name = 'extra manifest'; Names = @($installerNames + 'wizard-build.json') },
        @{ Name = 'extra private key'; Names = @($installerNames + 'private.pfx') },
        @{ Name = 'case variant'; Names = @($installerNames[0].ToLowerInvariant(), $installerNames[1]) },
        @{ Name = 'preview substitution'; Names = @("WinAirPlayAudio-$version-Setup-Preview.exe", $installerNames[1]) },
        @{ Name = 'duplicate executable'; Names = @($installerNames[0], $installerNames[0]) },
        @{ Name = 'traversal substitution'; Names = @('../' + $installerNames[0], $installerNames[1]) },
        @{ Name = 'directory substitution'; Names = @('nested/' + $installerNames[0], $installerNames[1]) },
        @{ Name = 'wrong executable version'; Names = @('WinAirPlayAudio-9.9.9-Setup.exe', $installerNames[1]) }
    )) {
        $fixture = New-InstallerFixtureArchive -Name ('installer-invalid-' + [Guid]::NewGuid().ToString('N')) -EntryNames $entries.Names
        Assert-Rejected "installer rejects $($entries.Name)" { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    }
    foreach ($attributes in @(0x400, 0x10, -1610612736)) {
        $fixture = New-InstallerFixtureArchive -Name ('installer-attributes-' + [Guid]::NewGuid().ToString('N')) `
            -AttributeEntry $installerNames[0] -Attributes $attributes
        Assert-Rejected "installer rejects reparse/directory/Unix-symlink attributes $attributes" `
            { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    }
    $fixture = New-InstallerFixtureArchive -Name 'installer-empty' -EmptyEntry $installerNames[0]
    Assert-Rejected 'installer rejects empty executable' { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-InstallerFixtureArchive -Name 'installer-oversized' -OversizedEntry $installerNames[0]
    Assert-Rejected 'installer rejects expanded executable above 32 MiB' { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-InstallerFixtureArchive -Name 'installer-corrupt-payload' -CorruptPayload
    Assert-Rejected 'installer corrupt payload removes all extraction output' { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-InstallerFixtureArchive -Name 'installer-wrong-checksum'
    [IO.File]::WriteAllText($fixture.Checksum, "$('0' * 64)  $([IO.Path]::GetFileName($fixture.Archive))`n")
    Assert-Rejected 'installer rejects archive checksum mismatch' { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-InstallerFixtureArchive -Name 'installer-multiline-checksum'
    [IO.File]::AppendAllText($fixture.Checksum, 'unexpected second checksum line')
    Assert-Rejected 'installer rejects multiline checksum' { Invoke-ExpandInstallerFixture $fixture } (Join-Path $fixture.Directory 'expanded')
    $fixture = New-InstallerFixtureArchive -Name 'installer-existing-destination'
    $existing = Join-Path $fixture.Directory 'expanded'
    $null = [IO.Directory]::CreateDirectory($existing)
    $sentinel = Join-Path $existing 'preserved.txt'
    [IO.File]::WriteAllText($sentinel, 'Retain existing data')
    Assert-Rejected 'installer refuses existing extraction destination' { Invoke-ExpandInstallerFixture $fixture } ''
    Assert-Fixture ([IO.File]::ReadAllText($sentinel) -ceq 'Retain existing data') 'Installer reader changed existing destination data.'

    # Real bounded public envelope, mocked GitHub only. No network or root trust changes.
    $publisher = Join-Path $repo '.github/scripts/Publish-Prerelease.ps1'
    $fixture = New-InstallerFixtureArchive -Name 'publisher'
    if (Get-Command gh.exe -CommandType Function -ErrorAction SilentlyContinue) { throw 'Refusing to replace an existing gh.exe function.' }
    $global:WinAirPlayArchiveGhMock = @{Commands=[Collections.Generic.List[object]]::new(); Draft=$true; BadDigest=$false; BadReleaseId=$false; Assets=@()}
    $global:WinAirPlayArchiveGhMock.Assets = @($fixture.Archive,$fixture.Checksum | ForEach-Object {
        $item=Get-Item -LiteralPath $_
        [pscustomobject]@{name=$item.Name; size=$item.Length; state='uploaded'; digest=('sha256:'+(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant())}
    })
    function global:gh.exe {
        $arguments=@($args)
        $state=$global:WinAirPlayArchiveGhMock
        $state.Commands.Add($arguments)
        $global:LASTEXITCODE=0
        if ($arguments[0] -ceq 'api' -and $arguments[1] -like '*/commits/*') { return ('1' * 40) }
        if ($arguments[0] -ceq 'api' -and $arguments[1] -like '*/releases/tags/*') {
            $global:LASTEXITCODE=1
            throw 'Published-by-tag lookup cannot find a draft.'
        }
        if ($arguments[0] -ceq 'api' -and $arguments[1] -like '*/releases/73') {
            if ('PATCH' -cin $arguments) { $state.Draft=$false; return }
            $assets = @($state.Assets | ForEach-Object { [pscustomobject]@{name=$_.name;size=$_.size;state=$_.state;digest=$(if ($state.BadDigest) {'sha256:'+('0'*64)} else {$_.digest})} })
            return ([pscustomobject]@{id=73; tag_name='v0.1.0'; draft=$state.Draft; prerelease=$true; assets=$assets} | ConvertTo-Json -Depth 5)
        }
        if ($arguments[0] -ceq 'release' -and $arguments[1] -ceq 'view') {
            return $(if ($state.BadReleaseId) { '../unexpected' } else { '73' })
        }
        if ($arguments[0] -ceq 'release' -and $arguments[1] -ceq 'list') { return '[]' }
        if ($arguments[0] -ceq 'release' -and $arguments[1] -ceq 'create') {
            $notesIndex = [Array]::IndexOf($arguments, '--notes-file')
            $state.Notes = [IO.File]::ReadAllText($arguments[$notesIndex + 1])
            $state.Draft=$true; return
        }
        throw 'Unexpected GitHub mock command.'
    }
    $installedGh=$true
    $publish=@{Version=$version;Tag="v$version";AssetDirectory=$fixture.Directory;Repository='example/WinAirPlayAudio'
        SourceCommit=$commit;SigningState='test-signed';ExpectedArchiveSha256=$fixture.Hash
        ExpectedSignerThumbprint=$certificate.Thumbprint;Publish=$true;Confirm=$false}
    $broadFixture = New-FixtureArchive -Name 'publisher-rejects-developer-bundle' -State test-signed
    $broadPublish = @{} + $publish
    $broadPublish.AssetDirectory = $broadFixture.Directory
    $broadPublish.ExpectedArchiveSha256 = $broadFixture.Hash
    Assert-Rejected 'publisher rejects full developer payload despite matching trusted hash' { & $publisher @broadPublish } ''
    Assert-Fixture ($global:WinAirPlayArchiveGhMock.Commands.Count -eq 0) 'Developer bundle reached GitHub publication.'
    & $publisher @publish
    $creates=@($global:WinAirPlayArchiveGhMock.Commands | Where-Object {$_[0] -ceq 'release' -and $_[1] -ceq 'create'})
    $edits=@($global:WinAirPlayArchiveGhMock.Commands | Where-Object {$_[0] -ceq 'api' -and $_[1] -like '*/releases/73' -and 'PATCH' -cin $_})
    Assert-Fixture ($creates.Count -eq 1 -and '--draft' -cin $creates[0] -and '--prerelease' -cin $creates[0] -and '--latest=false' -cin $creates[0] -and '--verify-tag' -cin $creates[0]) 'Signed publication was visible before verified upload.'
    Assert-Fixture ($edits.Count -eq 1 -and 'draft=false' -cin $edits[0] -and 'prerelease=true' -cin $edits[0] -and 'make_latest=false' -cin $edits[0] -and -not $global:WinAirPlayArchiveGhMock.Draft) 'Signed publication did not automatically publish the same verified draft ID.'
    Assert-Fixture ($global:WinAirPlayArchiveGhMock.Notes.Contains('The ZIP contains exactly') -and
        $global:WinAirPlayArchiveGhMock.Notes.Contains($installerNames[0]) -and
        $global:WinAirPlayArchiveGhMock.Notes.Contains($installerNames[1]) -and
        -not $global:WinAirPlayArchiveGhMock.Notes.Contains('Follow INSTALL.md')) 'Published notes do not describe the installer-only download.'
    $cases++
    Write-Host 'PASS: stage, verify digests and automatically publish'
    $global:WinAirPlayArchiveGhMock.Commands.Clear()
    $publish.Publish=$false
    & $publisher @publish
    Assert-Fixture (@($global:WinAirPlayArchiveGhMock.Commands | Where-Object {'PATCH' -cin $_}).Count -eq 0 -and $global:WinAirPlayArchiveGhMock.Draft) 'Draft-only invocation unexpectedly published.'
    $cases++
    Write-Host 'PASS: explicit draft-only invocation does not publish'
    $global:WinAirPlayArchiveGhMock.Commands.Clear()
    $publish.Publish=$true
    $publish.ExpectedArchiveSha256='0'*64
    Assert-Rejected 'publisher rejects a hash not anchored by signing job' { & $publisher @publish } ''
    Assert-Fixture ($global:WinAirPlayArchiveGhMock.Commands.Count -eq 0) 'Wrong trusted hash reached GitHub.'
    $publish.ExpectedArchiveSha256=$fixture.Hash
    $global:WinAirPlayArchiveGhMock.BadDigest=$true
    Assert-Rejected 'publisher refuses mismatched remote asset digest' { & $publisher @publish } ''
    Assert-Fixture (@($global:WinAirPlayArchiveGhMock.Commands | Where-Object {'PATCH' -cin $_}).Count -eq 0) 'Unverified remote assets were published.'
    $global:WinAirPlayArchiveGhMock.Commands.Clear()
    $global:WinAirPlayArchiveGhMock.BadDigest=$false
    $global:WinAirPlayArchiveGhMock.BadReleaseId=$true
    Assert-Rejected 'publisher rejects an unsafe draft release ID' { & $publisher @publish } ''
    Assert-Fixture (@($global:WinAirPlayArchiveGhMock.Commands | Where-Object {'PATCH' -cin $_}).Count -eq 0) 'Unsafe release ID reached publication.'
    Write-Host "Archive/publication fixture checks passed ($cases cases). Structural fixtures are not real driver signatures."
}
finally {
    if ($hadExitVariable) { $global:LASTEXITCODE = $previousExitCode }
    else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    if ($installedGh) {
        Remove-Item -LiteralPath Function:gh.exe -ErrorAction Stop
        Remove-Variable -Name WinAirPlayArchiveGhMock -Scope Global -ErrorAction Stop
        if (Get-Command gh.exe -CommandType Function -ErrorAction SilentlyContinue) {
            throw 'Archive fixture failed to remove its GitHub CLI mock.'
        }
    }
    if ($certificate) { $certificate.Dispose() }
    $rsa.Dispose()
    $full=[IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($full) -cne [IO.Path]::GetFullPath($parent) -or [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') { throw 'Refusing archive fixture cleanup outside owned scope.' }
    if (Test-Path -LiteralPath $full) {
        if (@(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing cleanup containing a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $full) { throw 'Archive fixture cleanup left residue.' }
    }
}
