[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$Tag,

    [Parameter(Mandatory)]
    [string]$AssetDirectory,

    [Parameter(Mandatory)]
    [string]$Repository,

    [Parameter(Mandatory)]
    [string]$SourceCommit,

    [ValidateSet('unsigned', 'test-signed')]
    [string]$SigningState = 'unsigned',

    [string]$ExpectedArchiveSha256,

    [string]$ExpectedSignerThumbprint,

    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$numeric = '(?:0|[1-9][0-9]*)'
$identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
$semver = "^$numeric\.$numeric\.$numeric(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
if ($Version.Length -gt 128 -or $Version -cnotmatch $semver -or $Tag -cne "v$Version") {
    throw 'Release version must be SemVer and the tag must equal v<Version>.'
}
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $SourceCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'A canonical owner/repository and a full lowercase Git commit SHA are required.'
}
$assetRoot = Get-Item -LiteralPath $AssetDirectory -Force -ErrorAction Stop
if (-not $assetRoot.PSIsContainer -or
    ($assetRoot.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Release assets must be a regular directory.'
}
if ($Publish -and $SigningState -cne 'test-signed') {
    throw 'Automatic publication requires an explicitly test-signed release.'
}
$archiveName = "WinAirPlayAudio-$Version-windows-x64-$SigningState.zip"
$checksumName = "$archiveName.sha256"
$expectedNames = @($archiveName, $checksumName)
$assets = @(Get-ChildItem -LiteralPath $assetRoot.FullName -Force -ErrorAction Stop)
if ($assets.Count -ne 2 -or
    @($assets | Where-Object {
            $_.PSIsContainer -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $_.Name -cnotin $expectedNames
        }).Count -ne 0) {
    throw 'Release assets must contain exactly the expected release ZIP and its SHA-256 file.'
}
$archive = Get-Item -LiteralPath (Join-Path $assetRoot.FullName $archiveName)
$checksum = Get-Item -LiteralPath (Join-Path $assetRoot.FullName $checksumName)
if ($archive.Length -le 0 -or $archive.Length -gt 128MB -or
    $checksum.Length -le 0 -or $checksum.Length -gt 512) {
    throw 'Release assets exceed the bounded archive/checksum size contract.'
}
$checksumBytes = [IO.File]::ReadAllBytes($checksum.FullName)
$checksumDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($checksumBytes)).ToLowerInvariant()
$checksumText = [Text.UTF8Encoding]::new($false, $true).GetString($checksumBytes).TrimStart([char]0xFEFF).TrimEnd("`r", "`n")
$checksumPattern = '^([0-9A-Fa-f]{64}) [ *]' + [regex]::Escape($archiveName) + '$'
if ($checksumText -cnotmatch $checksumPattern) {
    throw 'The SHA-256 file must contain exactly one digest and the expected archive basename.'
}
$expectedHash = $Matches[1].ToUpperInvariant()
$actualHash = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash
if ($actualHash -cne $expectedHash) {
    throw 'The release archive does not match its SHA-256.'
}
if ($SigningState -ceq 'test-signed') {
    if ($ExpectedArchiveSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        $ExpectedSignerThumbprint -cnotmatch '^[0-9A-F]{40}$' -or
        $actualHash -cne $ExpectedArchiveSha256) {
        throw 'Test-signed publication requires the exact archive hash and signer pin from the successful signing job.'
    }
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'scripts/ReleaseLayout.psm1') -Force
    $scratchParent = Join-Path $repoRoot '.local/diagnostics/release-publication'
    $null = [IO.Directory]::CreateDirectory($scratchParent)
    $scratch = Join-Path $scratchParent ([Guid]::NewGuid().ToString('N'))
    try {
        # Structural/hash validation only. The trusted job hash binds these
        # exact bytes to the real signature/catalog checks in the signing job.
        $null = Expand-WinAirPlayInstallerArchive -ArchivePath $archive.FullName `
            -ChecksumPath $checksum.FullName -Destination $scratch -Version $Version
    }
    finally {
        if (Test-Path -LiteralPath $scratch) {
            $full = [IO.Path]::GetFullPath($scratch)
            if ([IO.Path]::GetDirectoryName($full) -cne [IO.Path]::GetFullPath($scratchParent) -or
                [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$' -or
                @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object {
                    $_.Attributes -band [IO.FileAttributes]::ReparsePoint
                }).Count -ne 0) { throw 'Refusing publication scratch cleanup outside the owned directory.' }
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
    }
}

if (-not $PSCmdlet.ShouldProcess(
        "$Repository / $Tag / $SourceCommit",
        "Create a $SigningState prerelease (publish=$Publish) containing only its ZIP and SHA-256")) {
    return
}
if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh.exe) is required to create the draft release.'
}
$encodedTag = [Uri]::EscapeDataString($Tag)
$remoteTagCommit = & gh.exe api "repos/$Repository/commits/$encodedTag" --jq .sha
if ($LASTEXITCODE -ne 0 -or $remoteTagCommit -cne $SourceCommit) {
    throw 'The remote release tag no longer points to the source commit that passed CI.'
}
$existing = & gh.exe release list --repo $Repository --limit 100 --json tagName
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query existing releases; refusing to create or overwrite a release.'
}
if (@($existing | ConvertFrom-Json | Where-Object tagName -CEQ $Tag).Count -ne 0) {
    throw "A release already exists for $Tag. Review that draft; this workflow never overwrites an existing release."
}
$notes = @"
Unsigned developer snapshot $Version from commit $SourceCommit.

This draft is a prerelease for source and build review. The ZIP is unsigned signing input, and is not a production driver distribution. Review its included installation guide and SHA-256 before isolated development testing.

CI covers pinned-toolchain formatting, Clippy, unit/process/mock integration tests, Debug/Release user-mode and driver builds, and bounded packaging. It does not establish audible receiver compatibility, installed-driver safety, Windows 10/ARM64 support, Driver Verifier/HLK/soak results, or production signing. AirPlay 2 remains unsupported.

Publication requires a maintainer to review the current release checklist and this draft. The workflow leaves both the draft and prerelease flags set.
"@
$title = "WinAirPlayAudio $Version (unsigned developer preview)"
if ($SigningState -ceq 'test-signed') {
    $title = "WinAirPlayAudio $Version (test-signed prerelease)"
    $notes = @"
Test-signed experimental prerelease $Version from commit $SourceCommit.

The ZIP contains exactly WinAirPlayAudio-$Version-Setup.exe and WinAirPlayAudio-$Version-Uninstall.exe. Setup embeds the prebuilt signed driver/service payload, required backend scripts, licenses and public DER test certificate; Uninstall embeds its own removal scripts. No compiler, WDK, private key or local signing is needed. After authenticating the download, extract both executables and run Setup. Keep the companion Uninstall executable outside the installed product directory for later removal.

Archive SHA-256: $actualHash
Test certificate thumbprint: $ExpectedSignerThumbprint

Requires Windows 11 x64 24H2+ and administrator access. GUI setup checks/provisions PowerShell and x64 VC++ runtimes, then guides explicitly approved test-mode preparation, manual reboot, public-certificate trust and clean installation. The uninstaller removes/verifies the product before optional trust cleanup and test-mode exit. Review Secure Boot/BitLocker recovery and other test-signed drivers first. No automatic reboot, Secure Boot or HVCI change occurs. Both GUI EXEs and the driver use the dedicated public test certificate; this does not provide Microsoft production certification or SmartScreen reputation.

IMPORTANT: Windows endpoint mute/volume does not control outgoing audio. Use receiver controls. Only experimental classic plaintext RAOP is implemented; AirPlay 2 is unsupported. Physical receiver, clean-host, privilege, lifecycle, soak, Verifier/HLK and production acceptance remain separate open gates. This test signature is not Microsoft production certification.

CI verifies source/version, formatting, Clippy, unit/process/mock tests, Debug/Release builds, package privacy, GUI compilation, actual driver/GUI test signatures and catalog membership, final manifests and normal/failure signing cleanup before publication. Those checks do not establish the open installed/hardware acceptance gates.
"@
}
$notesRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.local/diagnostics/release-notes'
$null = [IO.Directory]::CreateDirectory($notesRoot)
$notesPath = Join-Path $notesRoot ([Guid]::NewGuid().ToString('N') + '.md')
try {
    [IO.File]::WriteAllText($notesPath, $notes, [Text.UTF8Encoding]::new($false))
    $publishArguments = @('release', 'create', $Tag, $archive.FullName, $checksum.FullName,
        '--repo', $Repository, '--verify-tag', '--target', $SourceCommit,
        '--title', $title, '--notes-file', $notesPath, '--draft', '--prerelease', '--latest=false')
    $expectedAssets = @{}
    foreach ($asset in @($archive, $checksum)) {
        $expectedAssets[$asset.Name] = @{
            Size=$asset.Length
            Digest='sha256:' + $(if ($asset.Name -ceq $archive.Name) { $actualHash.ToLowerInvariant() } else { $checksumDigest })
        }
    }
    & gh.exe @publishArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Creating the prerelease failed. Inspect any partial draft before retrying.'
    }
    if ($SigningState -ceq 'test-signed') {
        # The published-by-tag REST endpoint excludes drafts. Resolve the
        # authenticated draft through gh, then use its stable numeric ID for
        # both pre-publication and final asset verification.
        $releaseId = & gh.exe release view $Tag --repo $Repository --json databaseId --jq .databaseId
        if ($LASTEXITCODE -ne 0 -or [string]$releaseId -cnotmatch '^[1-9][0-9]*$') {
            throw 'Cannot resolve the uploaded draft release ID; it must not be published.'
        }
        function Assert-RemoteRelease {
            param([bool]$ExpectedDraft)
            $tagCommit = & gh.exe api "repos/$Repository/commits/$encodedTag" --jq .sha
            if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $SourceCommit) {
                throw 'The release tag changed while uploading or publishing.'
            }
            $response = & gh.exe api "repos/$Repository/releases/$releaseId"
            if ($LASTEXITCODE -ne 0) { throw 'Cannot verify uploaded release; it must not be published.' }
            $remote = $response | ConvertFrom-Json -ErrorAction Stop
            if ([string]$remote.id -cne [string]$releaseId -or $remote.tag_name -cne $Tag -or
                $remote.draft -isnot [bool] -or $remote.draft -ne $ExpectedDraft -or
                $remote.prerelease -isnot [bool] -or -not $remote.prerelease -or
                @($remote.assets).Count -ne $expectedAssets.Count) {
                throw 'Remote prerelease identity, flags or asset count failed verification.'
            }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($asset in $remote.assets) {
                if (-not $expectedAssets.ContainsKey($asset.name) -or -not $seen.Add($asset.name) -or
                    $asset.state -cne 'uploaded' -or $asset.size -ne $expectedAssets[$asset.name].Size -or
                    $asset.digest -cne $expectedAssets[$asset.name].Digest) {
                    throw 'Remote prerelease asset name, size, state or SHA-256 failed verification.'
                }
            }
        }
        Assert-RemoteRelease -ExpectedDraft $true
        if ($Publish) {
            # Assets are complete and authenticated before the release becomes
            # visible. This final transition is automatic, not a manual gate.
            & gh.exe api "repos/$Repository/releases/$releaseId" --method PATCH `
                -F draft=false -F prerelease=true -f make_latest=false --silent
            if ($LASTEXITCODE -ne 0) { throw 'Publishing the verified draft failed; inspect its remote state.' }
            Assert-RemoteRelease -ExpectedDraft $false
        }
    }
}
finally { Remove-Item -LiteralPath $notesPath -Force -ErrorAction Stop }
