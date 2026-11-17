[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MetadataPath,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$metadataFile = (Resolve-Path -LiteralPath $MetadataPath -ErrorAction Stop).Path
if ((Get-Item -LiteralPath $metadataFile -Force).Attributes -band
    [IO.FileAttributes]::ReparsePoint) {
    throw "Refusing reparse-point Cargo metadata: $metadataFile"
}
$metadataInfo = Get-Item -LiteralPath $metadataFile
if ($metadataInfo.Length -gt 16MB) {
    throw "Cargo metadata exceeds the 16 MiB packaging bound: $metadataFile"
}
$metadata = Get-Content -LiteralPath $metadataFile -Raw |
    ConvertFrom-Json -Depth 100 -ErrorAction Stop
$registryPackages = @($metadata.packages |
        Where-Object { $_.source -like 'registry+*' } |
        Sort-Object name, version)
if ($registryPackages.Count -eq 0 -or $registryPackages.Count -gt 512) {
    throw "Unexpected registry dependency count: $($registryPackages.Count)"
}

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('WinAirPlayAudio locked Rust dependency license bundle')
[void]$builder.AppendLine('Generated from cargo metadata --locked; hashes are SHA-256.')
[void]$builder.AppendLine()
$licenseFileCount = 0
foreach ($package in $registryPackages) {
    $manifest = [IO.Path]::GetFullPath([string]$package.manifest_path)
    $sourceDirectory = [IO.Path]::GetDirectoryName($manifest)
    $sourceItem = Get-Item -LiteralPath $sourceDirectory -Force -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Dependency source directory is unsafe: $sourceDirectory"
    }
    $licenseFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -Force -File |
            Where-Object {
                $_.Name -match '^(?i:LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)(?:[._-].*)?$'
            } |
            Sort-Object Name)
    if ($licenseFiles.Count -eq 0) {
        throw "No top-level license/notice file found for $($package.name) $($package.version)."
    }

    [void]$builder.AppendLine(('=' * 78))
    [void]$builder.AppendLine("Package: $($package.name) $($package.version)")
    [void]$builder.AppendLine("Declared license: $($package.license)")
    [void]$builder.AppendLine("Source: $($package.source)")
    foreach ($licenseFile in $licenseFiles) {
        if ($licenseFile.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Dependency license is a reparse point: $($licenseFile.FullName)"
        }
        if ($licenseFile.Length -gt 1MB) {
            throw "Dependency license exceeds the 1 MiB per-file bound: $($licenseFile.FullName)"
        }
        $licenseFileCount++
        if ($licenseFileCount -gt 1024) {
            throw 'Dependency license bundle exceeds 1,024 source files.'
        }
        [void]$builder.AppendLine()
        [void]$builder.AppendLine(
            "----- $($licenseFile.Name) | SHA-256 $((Get-FileHash -LiteralPath $licenseFile.FullName -Algorithm SHA256).Hash) -----")
        [void]$builder.AppendLine((Get-Content -LiteralPath $licenseFile.FullName -Raw))
    }
    [void]$builder.AppendLine()
    if ($builder.Length -gt 32MB) {
        throw 'Dependency license bundle exceeds the 32 MiB output bound.'
    }
}

$fullOutput = [IO.Path]::GetFullPath($OutputPath)
$outputParent = [IO.Path]::GetDirectoryName($fullOutput)
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "License-bundle output directory does not exist: $outputParent"
}
$builder.ToString() | Set-Content -LiteralPath $fullOutput -Encoding UTF8
Write-Host "Collected $licenseFileCount license/notice files for $($registryPackages.Count) locked registry packages."
