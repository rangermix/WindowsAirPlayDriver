Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WorkspacePackages = @(
    'winairplay-service',
    'winairplay-shared', 'winairplay-tools'
)

function ConvertTo-ProjectSemVer {
    param([Parameter(Mandatory)][string]$Version)

    $pattern = '\A(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z'
    $match = [regex]::Match($Version, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { throw "Invalid SemVer: '$Version'. Expected MAJOR.MINOR.PATCH with optional prerelease/build identifiers." }
    foreach ($field in @('major', 'minor', 'patch')) {
        $value = [System.Numerics.BigInteger]::Parse($match.Groups[$field].Value)
        if ($value -gt 65534) { throw "SemVer $field exceeds the Windows DriverVer maximum of 65534." }
    }
    $prerelease = @()
    if ($match.Groups['pre'].Success) {
        $prerelease = @($match.Groups['pre'].Value.Split('.'))
        foreach ($identifier in $prerelease) {
            if ($identifier -match '^[0-9]+$' -and $identifier.Length -gt 1 -and $identifier[0] -eq '0') {
                throw "Numeric SemVer prerelease identifiers cannot have leading zeroes: '$identifier'."
            }
        }
    }
    [pscustomobject]@{
        Version = $Version
        Major = [int]$match.Groups['major'].Value
        Minor = [int]$match.Groups['minor'].Value
        Patch = [int]$match.Groups['patch'].Value
        Prerelease = $prerelease
    }
}

function Compare-ProjectSemVer {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $leftVersion = ConvertTo-ProjectSemVer $Left
    $rightVersion = ConvertTo-ProjectSemVer $Right
    foreach ($field in @('Major', 'Minor', 'Patch')) {
        $comparison = $leftVersion.$field.CompareTo($rightVersion.$field)
        if ($comparison -ne 0) { return $comparison }
    }
    if ($leftVersion.Prerelease.Count -eq 0 -and $rightVersion.Prerelease.Count -eq 0) { return 0 }
    if ($leftVersion.Prerelease.Count -eq 0) { return 1 }
    if ($rightVersion.Prerelease.Count -eq 0) { return -1 }
    for ($index = 0; $index -lt [Math]::Min($leftVersion.Prerelease.Count, $rightVersion.Prerelease.Count); $index++) {
        $leftPart = $leftVersion.Prerelease[$index]
        $rightPart = $rightVersion.Prerelease[$index]
        $leftNumeric = $leftPart -match '^[0-9]+$'
        $rightNumeric = $rightPart -match '^[0-9]+$'
        if ($leftNumeric -and $rightNumeric) {
            $comparison = ([System.Numerics.BigInteger]::Parse($leftPart)).CompareTo([System.Numerics.BigInteger]::Parse($rightPart))
        }
        elseif ($leftNumeric) { return -1 }
        elseif ($rightNumeric) { return 1 }
        else { $comparison = [StringComparer]::Ordinal.Compare($leftPart, $rightPart) }
        if ($comparison -ne 0) { return $comparison }
    }
    return $leftVersion.Prerelease.Count.CompareTo($rightVersion.Prerelease.Count)
}

function New-VersionState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $expectedFields = @('schema_version', 'version', 'driver_revision', 'driver_date')
    if ($Record.Count -ne $expectedFields.Count -or @($Record.Keys | Where-Object { $_ -cnotin $expectedFields }).Count -gt 0) {
        throw 'version.json must contain only schema_version, version, driver_revision and driver_date.'
    }
    if (($Record.schema_version -isnot [int] -and $Record.schema_version -isnot [long]) -or $Record.schema_version -ne 1) { throw 'Unsupported version.json schema_version; expected integer 1.' }
    if ($Record.version -isnot [string] -or $Record.driver_date -isnot [string]) { throw 'Version and driver_date must be strings.' }
    if (($Record.driver_revision -isnot [int] -and $Record.driver_revision -isnot [long]) -or $Record.driver_revision -lt 0 -or $Record.driver_revision -gt 65534) {
        throw 'driver_revision must be an integer from 0 through 65534.'
    }
    $semantic = ConvertTo-ProjectSemVer $Record.version
    $date = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Record.driver_date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "Invalid driver_date '$($Record.driver_date)'; expected a real yyyy-MM-dd date."
    }
    $driverVersion = '{0}.{1}.{2}.{3}' -f $semantic.Major, $semantic.Minor, $semantic.Patch, $Record.driver_revision
    if ($driverVersion -eq '0.0.0.0') { throw 'Windows DriverVer 0.0.0.0 is invalid.' }
    [pscustomobject]@{
        Version = $Record.version
        Semantic = $semantic
        DriverRevision = [int]$Record.driver_revision
        DriverDate = $Record.driver_date
        Date = $date
        InfDate = $date.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
        DriverVersion = $driverVersion
    }
}

function Get-VersionState {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $json = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'version.json') -Raw
    $document = [Text.Json.JsonDocument]::Parse($json)
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'version.json must be a JSON object.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "Duplicate version.json property: $($property.Name)" }
        }
        $record = $json | ConvertFrom-Json -AsHashtable
    }
    finally { $document.Dispose() }
    if ($record -isnot [System.Collections.IDictionary]) { throw 'version.json must be a JSON object.' }
    New-VersionState -Record $record
}

function Get-VersionHeader {
    param([Parameter(Mandatory)]$State)
    $numeric = $State.DriverVersion.Replace('.', ',')
    @"
#pragma once
// Generated from version.json by scripts/Version.ps1. Do not edit independently.
#define WINAIRPLAY_SEMVER_STR "$($State.Version)"
#define WINAIRPLAY_DRIVER_VERSION $numeric
#define WINAIRPLAY_DRIVER_VERSION_STR "$($State.DriverVersion)"
"@ + "`n"
}

function Get-RequiredMatch {
    param([string]$Text, [string]$Pattern, [string]$Description)
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected exactly one $Description; found $($matches.Count)." }
    return $matches[0]
}

function Get-WorkspaceVersionMatch {
    param([string]$Text)
    $block = Get-RequiredMatch $Text '(?ms)^\[workspace\.package\][ \t]*\r?\n(?<body>.*?)(?=^\[|\z)' 'Cargo workspace.package block'
    $version = Get-RequiredMatch $block.Groups['body'].Value '(?m)^version[ \t]*=[ \t]*"(?<version>[^"]+)"' 'Cargo workspace version'
    [pscustomobject]@{ Block = $block; Version = $version }
}

function Get-LockVersionMatch {
    param([string]$Text, [string]$Name)
    $pattern = '(?m)^name[ \t]*=[ \t]*"' + [regex]::Escape($Name) + '"\r?\nversion[ \t]*=[ \t]*"(?<version>[^"]+)"'
    Get-RequiredMatch $Text $pattern "Cargo.lock package $Name"
}

function Test-VersionConsistency {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [string]$Tag)
    $state = Get-VersionState $RepositoryRoot
    if ($Tag) {
        if (-not $Tag.StartsWith('v', [StringComparison]::Ordinal)) { throw 'Release tags must start with v followed by the exact SemVer.' }
        $null = ConvertTo-ProjectSemVer $Tag.Substring(1)
        if ($Tag -cne ('v' + $state.Version)) { throw "Release tag '$Tag' does not match canonical version v$($state.Version)." }
    }
    $cargo = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Cargo.toml') -Raw
    $workspace = Get-WorkspaceVersionMatch $cargo
    if ($workspace.Version.Groups['version'].Value -cne $state.Version) { throw 'Cargo.toml workspace version differs from version.json.' }
    $lock = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Cargo.lock') -Raw
    foreach ($name in $script:WorkspacePackages) {
        $match = Get-LockVersionMatch $lock $name
        if ($match.Groups['version'].Value -cne $state.Version) { throw "Cargo.lock $name version differs from version.json." }
    }
    $inx = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'driver/WinAirPlayAudio.inx') -Raw
    $directive = Get-RequiredMatch $inx '(?m)^DriverVer[ \t]*=[ \t]*(?<date>[0-9/]+),(?<version>[0-9.]+)' 'INF DriverVer directive'
    if ($directive.Groups['date'].Value -cne $state.InfDate -or $directive.Groups['version'].Value -cne $state.DriverVersion) { throw 'INF DriverVer differs from version.json.' }
    $project = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'driver/WinAirPlayAudio.vcxproj') -Raw
    $dateStamp = Get-RequiredMatch $project '<DateStamp>(?<value>[^<]+)</DateStamp>' 'driver project DateStamp'
    $timeStamp = Get-RequiredMatch $project '<TimeStamp>(?<value>[^<]+)</TimeStamp>' 'driver project TimeStamp'
    if ($dateStamp.Groups['value'].Value -cne $state.InfDate -or $timeStamp.Groups['value'].Value -cne $state.DriverVersion) { throw 'Driver project stamp differs from version.json.' }
    $header = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'driver/Source/Inc/version.h') -Raw
    if ($header.Replace("`r`n", "`n") -cne (Get-VersionHeader $state).Replace("`r`n", "`n")) { throw 'Driver version.h differs from generated canonical version.' }
    $resource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'driver/WinAirPlayAudio.rc') -Raw
    foreach ($pattern in @(
            '(?m)^#include "version\.h"\r?$',
            '(?m)^#define VER_PRODUCTVERSION[ \t]+WINAIRPLAY_DRIVER_VERSION\r?$',
            '(?m)^#define VER_PRODUCTVERSION_STR[ \t]+WINAIRPLAY_SEMVER_STR\r?$',
            '(?m)^#define VER_FILEVERSION[ \t]+WINAIRPLAY_DRIVER_VERSION\r?$',
            '(?m)^#define VER_FILEVERSION_STR[ \t]+WINAIRPLAY_DRIVER_VERSION_STR\r?$',
            '(?m)^#define VER_PRODUCTNAME_STR[ \t]+"WinAirPlayAudio"\r?$')) {
        $null = Get-RequiredMatch $resource $pattern 'canonical driver resource definition'
    }
    return $state
}

function Update-ProjectVersion {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][int]$DriverRevision, [Parameter(Mandatory)][string]$DriverDate)
    $current = Test-VersionConsistency $RepositoryRoot
    $next = New-VersionState ([ordered]@{ schema_version = 1; version = $Version; driver_revision = $DriverRevision; driver_date = $DriverDate })
    if ((Compare-ProjectSemVer $next.Version $current.Version) -le 0) { throw 'New SemVer must have greater precedence than the current version; build metadata alone is not a release increment.' }
    if ([version]$next.DriverVersion -le [version]$current.DriverVersion) { throw 'Windows DriverVer must increase; increment driver_revision when advancing a prerelease within the same version core.' }
    if ($next.Date -lt $current.Date) { throw 'Driver package date cannot move backwards.' }

    $paths = @('version.json', 'Cargo.toml', 'Cargo.lock', 'driver/WinAirPlayAudio.inx', 'driver/WinAirPlayAudio.vcxproj', 'driver/Source/Inc/version.h')
    $originalBytes = [ordered]@{}
    $updated = [ordered]@{}
    foreach ($relative in $paths) {
        $path = Join-Path $RepositoryRoot $relative
        $originalBytes[$path] = [IO.File]::ReadAllBytes($path)
        $updated[$path] = [IO.File]::ReadAllText($path)
    }
    $updated[(Join-Path $RepositoryRoot 'version.json')] = ([ordered]@{ schema_version = 1; version = $next.Version; driver_revision = $next.DriverRevision; driver_date = $next.DriverDate } | ConvertTo-Json) + "`n"
    $cargoPath = Join-Path $RepositoryRoot 'Cargo.toml'
    $workspace = Get-WorkspaceVersionMatch $updated[$cargoPath]
    $oldBlock = $workspace.Block.Value
    $newBlock = $oldBlock.Replace('version = "' + $current.Version + '"', 'version = "' + $next.Version + '"')
    if ($newBlock -ceq $oldBlock) { throw 'Cargo workspace version has unexpected formatting; no files were changed.' }
    $updated[$cargoPath] = $updated[$cargoPath].Substring(0, $workspace.Block.Index) + $newBlock + $updated[$cargoPath].Substring($workspace.Block.Index + $workspace.Block.Length)
    $lockPath = Join-Path $RepositoryRoot 'Cargo.lock'
    foreach ($name in $script:WorkspacePackages) {
        $match = Get-LockVersionMatch $updated[$lockPath] $name
        $group = $match.Groups['version']
        $updated[$lockPath] = $updated[$lockPath].Substring(0, $group.Index) + $next.Version + $updated[$lockPath].Substring($group.Index + $group.Length)
    }
    $inxPath = Join-Path $RepositoryRoot 'driver/WinAirPlayAudio.inx'
    $updated[$inxPath] = [regex]::Replace($updated[$inxPath], '(?m)^DriverVer[ \t]*=[ \t]*[0-9/]+,[0-9.]+', ('DriverVer   = ' + $next.InfDate + ',' + $next.DriverVersion))
    $projectPath = Join-Path $RepositoryRoot 'driver/WinAirPlayAudio.vcxproj'
    $updated[$projectPath] = [regex]::Replace($updated[$projectPath], '<DateStamp>[^<]+</DateStamp>', ('<DateStamp>' + $next.InfDate + '</DateStamp>'))
    $updated[$projectPath] = [regex]::Replace($updated[$projectPath], '<TimeStamp>[^<]+</TimeStamp>', ('<TimeStamp>' + $next.DriverVersion + '</TimeStamp>'))
    $updated[(Join-Path $RepositoryRoot 'driver/Source/Inc/version.h')] = Get-VersionHeader $next

    $temporary = [ordered]@{}
    $written = [Collections.Generic.List[string]]::new()
    try {
        foreach ($path in $updated.Keys) {
            $temp = $path + '.version-' + [Guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temp, $updated[$path], [Text.UTF8Encoding]::new($false))
            $temporary[$path] = $temp
        }
        foreach ($path in $updated.Keys) {
            if (-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($path), $originalBytes[$path])) { throw "File changed during version update: $path" }
            [IO.File]::Move($temporary[$path], $path, $true)
            $written.Add($path)
        }
        return Test-VersionConsistency $RepositoryRoot
    }
    catch {
        $failure = $_
        $rollbackFailures = [Collections.Generic.List[string]]::new()
        foreach ($path in $written) {
            try { [IO.File]::WriteAllBytes($path, $originalBytes[$path]) }
            catch { $rollbackFailures.Add("$path`: $($_.Exception.Message)") }
        }
        if ($rollbackFailures.Count -gt 0) { throw "Version update failed: $($failure.Exception.Message). Rollback also failed: $($rollbackFailures -join '; ')" }
        throw $failure
    }
    finally {
        foreach ($temp in $temporary.Values) {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
}

Export-ModuleMember -Function ConvertTo-ProjectSemVer, Compare-ProjectSemVer, Get-VersionState, Test-VersionConsistency, Update-ProjectVersion
