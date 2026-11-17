[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$buildDriver = Join-Path $repoRoot 'driver\Build-Driver.ps1'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-WinAirPlayPackageSourceState {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $sourceCommit = @(& git -C $RepositoryRoot rev-parse --verify HEAD)
    if ($LASTEXITCODE -ne 0 -or $sourceCommit.Count -ne 1 -or
        $sourceCommit[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Package provenance requires a Git checkout with a recorded 40-hex source commit.'
    }
    $sourceStatus = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect package source status.' }
    return [pscustomobject]@{
        SourceCommit = $sourceCommit[0]
        SourceTreeDirty = ($sourceStatus.Count -ne 0)
    }
}

function ConvertTo-WinAirPlayPublicCargoMetadata {
    param([Parameter(Mandatory)][object]$Metadata)

    # Publish coordinates and the resolved dependency graph, never local paths.
    # The unmodified metadata is used separately to locate dependency licenses.
    $packageIds = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal)
    $publicIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $packages = @($Metadata.packages | Sort-Object name, version, source |
        ForEach-Object {
            $name = [string]$_.name
            $version = [string]$_.version
            $source = if ($null -eq $_.source) { $null } else { [string]$_.source }
            if ($name -notmatch '^[A-Za-z0-9_-]+$' -or
                $version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?$') {
                throw 'Cargo inventory contains invalid package coordinates.'
            }
            if ($null -ne $source) {
                $sourceUri = $null
                if ($source -notmatch '^(?:registry|sparse|git)\+https://[^\s\\]+$' -or
                    -not [Uri]::TryCreate(
                        $source.Substring($source.IndexOf('+') + 1),
                        [UriKind]::Absolute,
                        [ref]$sourceUri) -or
                    $sourceUri.Scheme -cne 'https' -or
                    [string]::IsNullOrWhiteSpace($sourceUri.Host) -or
                    -not [string]::IsNullOrEmpty($sourceUri.UserInfo)) {
                    throw "Cargo inventory source must be a credential-free public HTTPS registry or repository: $name $version"
                }
            }
            $publicId = if ($null -eq $source) {
                "workspace+$name@$version"
            }
            else {
                "$source#$name@$version"
            }
            if (-not $publicIds.Add($publicId)) {
                throw "Cargo inventory has ambiguous package coordinates: $name $version"
            }
            $packageIds.Add([string]$_.id, $publicId)
            [pscustomobject][ordered]@{
                id = $publicId
                name = $name
                version = $version
                source = $source
                license = $_.license
            }
        })

    function Resolve-PublicPackageId {
        param([Parameter(Mandatory)][string]$Id)
        if (-not $packageIds.ContainsKey($Id)) {
            throw 'Cargo inventory dependency graph references an unknown package.'
        }
        return $packageIds[$Id]
    }

    $nodes = @($Metadata.resolve.nodes | ForEach-Object {
        $node = $_
        [pscustomobject][ordered]@{
            id = Resolve-PublicPackageId -Id ([string]$node.id)
            dependencies = @($node.dependencies | ForEach-Object {
                Resolve-PublicPackageId -Id ([string]$_)
            } | Sort-Object)
            deps = @($node.deps | Sort-Object name, pkg | ForEach-Object {
                [pscustomobject][ordered]@{
                    name = $_.name
                    pkg = Resolve-PublicPackageId -Id ([string]$_.pkg)
                    dep_kinds = @($_.dep_kinds | ForEach-Object {
                        [pscustomobject][ordered]@{
                            kind = $_.kind
                            target = $_.target
                        }
                    })
                }
            })
            features = @($node.features | Sort-Object)
        }
    } | Sort-Object id)

    return [pscustomobject][ordered]@{
        inventory_format = 'winairplay-cargo-dependency-inventory-v1'
        cargo_metadata_version = $Metadata.version
        target = 'x86_64-pc-windows-msvc'
        packages = $packages
        workspace_members = @($Metadata.workspace_members | ForEach-Object {
            Resolve-PublicPackageId -Id ([string]$_)
        } | Sort-Object)
        resolve = [pscustomobject][ordered]@{
            root = if ($null -eq $Metadata.resolve.root) {
                $null
            }
            else {
                Resolve-PublicPackageId -Id ([string]$Metadata.resolve.root)
            }
            nodes = $nodes
        }
    }
}

& (Join-Path $repoRoot 'scripts\Version.ps1') -Check
$buildSourceState = Get-WinAirPlayPackageSourceState -RepositoryRoot $repoRoot

# This script is also a standalone packaging entry point, so it builds both
# user-mode and driver artifacts rather than assuming a prior shell history.
$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source
$cargoArguments = @(
    '+1.97.1',
    'build',
    '--workspace',
    '--locked',
    '--bins',
    '--target',
    'x86_64-pc-windows-msvc'
)
if ($Configuration -eq 'Release') {
    $cargoArguments += '--release'
}
& (Join-Path $repoRoot 'scripts\Invoke-Cargo.ps1') -CargoArguments $cargoArguments
& $buildDriver -Configuration $Configuration

$packageDirectory = Join-Path $repoRoot "driver\out\package\$Configuration\x64"
$expectedPackageNames = @(Get-WinAirPlayPackageFileNames)
$runtimeNames = @(Get-WinAirPlayRuntimeFileNames)
$requiredNames = @($expectedPackageNames | Where-Object { $_ -notin $runtimeNames })
foreach ($name in $requiredNames) {
    $path = Join-Path $packageDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "WDK package build did not produce required file: $path"
    }
}

$cargoProfile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$cargoOutput = Join-Path $repoRoot "target\x86_64-pc-windows-msvc\$cargoProfile"
$userModeNames = @($runtimeNames | Where-Object { [IO.Path]::GetExtension($_) -ieq '.exe' })
foreach ($name in $userModeNames) {
    $source = Join-Path $cargoOutput $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "User-mode build did not produce required file: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $packageDirectory $name) -Force
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.example.json') `
    -Destination (Join-Path $packageDirectory 'config.example.json') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') `
    -Destination (Join-Path $packageDirectory 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'driver\LICENSE.microsoft-samples.txt') `
    -Destination (Join-Path $packageDirectory 'LICENSE.microsoft-samples.txt') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'version.json') `
    -Destination (Join-Path $packageDirectory 'version.json') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') `
    -Destination (Join-Path $packageDirectory 'THIRD_PARTY_NOTICES.md') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') `
    -Destination (Join-Path $packageDirectory 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\build-and-install.md') `
    -Destination (Join-Path $packageDirectory 'BUILD-AND-INSTALL.md') -Force

$sbomPath = Join-Path $packageDirectory 'cargo-metadata.json'
$rawMetadataDirectory = Join-Path $repoRoot ".local\diagnostics\package\$Configuration-x64"
New-Item -ItemType Directory -Path $rawMetadataDirectory -Force | Out-Null
$rawMetadataPath = Join-Path $rawMetadataDirectory 'cargo-metadata.raw.json'
& $cargo '+1.97.1' metadata `
    --locked `
    --format-version 1 `
    --filter-platform x86_64-pc-windows-msvc `
    --manifest-path (Join-Path $repoRoot 'Cargo.toml') |
    Set-Content -LiteralPath $rawMetadataPath -Encoding UTF8
if ($LASTEXITCODE -ne 0) {
    throw "Cargo dependency inventory failed with exit code $LASTEXITCODE."
}
& (Join-Path $PSScriptRoot 'New-RustLicenseBundle.ps1') `
    -MetadataPath $rawMetadataPath `
    -OutputPath (Join-Path $packageDirectory 'RUST-DEPENDENCY-LICENSES.txt')
$rawMetadata = Get-Content -LiteralPath $rawMetadataPath -Raw |
    ConvertFrom-Json -Depth 100 -ErrorAction Stop
ConvertTo-WinAirPlayPublicCargoMetadata -Metadata $rawMetadata |
    ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $sbomPath -Encoding UTF8

$manifestPath = Join-Path $packageDirectory 'package-manifest.json'
$preManifestEntries = @(Get-ChildItem `
        -LiteralPath $packageDirectory `
        -Force `
        -ErrorAction Stop)
$unexpectedEntries = @($preManifestEntries | Where-Object {
        $_.PSIsContainer -or $_.Name -notin $expectedPackageNames
    })
$missingPayloads = @($expectedPackageNames |
        Where-Object {
            $_ -cne 'package-manifest.json' -and
            $_ -notin @($preManifestEntries | ForEach-Object Name)
        })
if ($unexpectedEntries.Count -ne 0 -or $missingPayloads.Count -ne 0) {
    throw "Package output is not the exact bounded file set. Missing=[$($missingPayloads -join ', ')]; unexpected=[$($unexpectedEntries.Name -join ', ')]. Remove only the reported stale entries and rebuild."
}
$files = foreach ($path in Get-ChildItem -LiteralPath $packageDirectory -File |
        Where-Object { $_.Name -ne 'package-manifest.json' } |
        Sort-Object Name) {
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    [pscustomobject]@{
        Name = $path.Name
        Length = $path.Length
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        SignatureStatus = $signature.Status.ToString()
        SignerThumbprint = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.Thumbprint
        } else {
            $null
        }
    }
}

$finalSourceState = Get-WinAirPlayPackageSourceState -RepositoryRoot $repoRoot
[pscustomobject]@{
    SchemaVersion = 1
    SourceCommit = $buildSourceState.SourceCommit
    SourceTreeDirty = [bool]($buildSourceState.SourceTreeDirty -or
        $finalSourceState.SourceTreeDirty -or
        $finalSourceState.SourceCommit -cne $buildSourceState.SourceCommit)
    Configuration = $Configuration
    Platform = 'x64'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    HardwareId = 'ROOT\WinAirPlayAudio'
    UserService = 'WinAirPlayAudioService'
    Files = @($files)
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

$finalEntries = @(Get-ChildItem `
        -LiteralPath $packageDirectory `
        -Force `
        -ErrorAction Stop)
if ($finalEntries.Count -ne $expectedPackageNames.Count -or
    @($finalEntries | Where-Object {
            $_.PSIsContainer -or $_.Name -notin $expectedPackageNames
        }).Count -ne 0) {
    throw 'Final package output does not contain the exact manifest-locked file set.'
}

Write-Host "Complete package ready: $packageDirectory"
Write-Host "Unsigned package manifest SHA-256: $((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash)"
Write-Host 'Signing and installation remain explicit installer steps.'
