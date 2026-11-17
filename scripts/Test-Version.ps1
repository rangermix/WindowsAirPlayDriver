[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Versioning.psm1') -Force
$script:Assertions = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Description)
    $script:Assertions++
    if ($Actual -cne $Expected) { throw "$Description`: expected '$Expected', observed '$Actual'." }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Description)
    $script:Assertions++
    $rejected = $false
    try { $null = & $Action }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Expected rejection: $Description" }
}

$validVersions = @('0.0.0', '0.1.0', '1.2.3-alpha.0', '1.2.3-0.3.7', '1.2.3-x-y-z.--', '1.2.3+001', '1.2.3-alpha+build.001', '65534.65534.65534')
foreach ($version in $validVersions) {
    Assert-Equal (ConvertTo-ProjectSemVer $version).Version $version "Valid SemVer $version"
}
foreach ($version in @('v1.2.3', '01.2.3', '1.02.3', '1.2.03', '1.2', '1.2.3-', '1.2.3-01', '1.2.3-a..b', '1.2.3+', '1.2.3+abc..def', '1.2.3 alpha', "1.2.3`n", '65535.0.0', '999999999999999999999.0.0')) {
    Assert-Rejected { ConvertTo-ProjectSemVer $version } "Invalid SemVer $version"
}
$sequence = @('1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '1.0.1', '1.1.0', '2.0.0')
for ($index = 1; $index -lt $sequence.Count; $index++) {
    Assert-Equal ((Compare-ProjectSemVer $sequence[$index - 1] $sequence[$index]) -lt 0) $true 'SemVer precedence order'
}
Assert-Equal (Compare-ProjectSemVer '1.0.0+build.1' '1.0.0+build.2') 0 'Build metadata has no precedence'
Assert-Equal ((Compare-ProjectSemVer '1.0.0-999999999999999999999' '1.0.0-1000000000000000000000') -lt 0) $true 'Large numeric prerelease identifiers'
Assert-Equal ((Compare-ProjectSemVer '1.0.0-A' '1.0.0-a') -lt 0) $true 'ASCII case-sensitive prerelease ordering'

$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $repository '.local/diagnostics/tests'))
$fixture = [IO.Path]::GetFullPath((Join-Path $evidenceRoot ('version-' + [Guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Version test fixture escaped diagnostics root.' }
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$fixtureFiles = @('version.json', 'Cargo.toml', 'Cargo.lock', 'driver/WinAirPlayAudio.inx', 'driver/WinAirPlayAudio.vcxproj', 'driver/Source/Inc/version.h', 'driver/WinAirPlayAudio.rc')
foreach ($relative in $fixtureFiles) {
    $destination = Join-Path $fixture $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository $relative) -Destination $destination
}

function Get-FixtureDigest {
    $values = foreach ($relative in $fixtureFiles) {
        (Get-FileHash -LiteralPath (Join-Path $fixture $relative) -Algorithm SHA256).Hash
    }
    return $values -join ':'
}

$baseline = Test-VersionConsistency -RepositoryRoot $fixture
Assert-Equal $baseline.Version ((Get-VersionState $repository).Version) 'Baseline fixture consistency'
$null = Test-VersionConsistency -RepositoryRoot $fixture -Tag ('v' + $baseline.Version)
$script:Assertions++
Assert-Rejected { Test-VersionConsistency -RepositoryRoot $fixture -Tag $baseline.Version } 'Tag requires v prefix'
Assert-Rejected { Test-VersionConsistency -RepositoryRoot $fixture -Tag 'v999.0.0' } 'Tag must match canonical version'

# Each independently versioned input must be checked, including driver resources.
$mutations = @{
    'Cargo.toml' = { param($text) $text.Replace('version = "' + $baseline.Version + '"', 'version = "0.0.0"') }
    'Cargo.lock' = { param($text) $text.Replace('name = "winairplay-tools"' + "`n" + 'version = "' + $baseline.Version + '"', 'name = "winairplay-tools"' + "`n" + 'version = "0.0.0"') }
    'driver/WinAirPlayAudio.inx' = { param($text) $text.Replace($baseline.DriverVersion, '0.0.0.1') }
    'driver/WinAirPlayAudio.vcxproj' = { param($text) $text.Replace('<TimeStamp>' + $baseline.DriverVersion + '</TimeStamp>', '<TimeStamp>0.0.0.1</TimeStamp>') }
    'driver/Source/Inc/version.h' = { param($text) $text.Replace('WINAIRPLAY_DRIVER_VERSION_STR', 'UNBOUND_DRIVER_VERSION_STR') }
    'driver/WinAirPlayAudio.rc' = { param($text) $text.Replace('"WinAirPlayAudio"', '"Windows"') }
}
foreach ($relative in $mutations.Keys) {
    $path = Join-Path $fixture $relative
    $original = [IO.File]::ReadAllText($path)
    $changed = & $mutations[$relative] ($original.Replace("`r`n", "`n"))
    if ($changed -ceq $original.Replace("`r`n", "`n")) { throw "Test fixture mutation did not change $relative." }
    [IO.File]::WriteAllText($path, $changed)
    Assert-Rejected { Test-VersionConsistency $fixture } "Version drift in $relative"
    $beforeRejectedWrite = Get-FixtureDigest
    Assert-Rejected { Update-ProjectVersion $fixture '0.2.0' 0 '2026-10-31' } "Drift blocks setter before mutation: $relative"
    Assert-Equal (Get-FixtureDigest) $beforeRejectedWrite 'Rejected inconsistent update preserves every file'
    [IO.File]::WriteAllText($path, $original)
}

$jsonPath = Join-Path $fixture 'version.json'
$originalJson = [IO.File]::ReadAllText($jsonPath)
foreach ($invalidJson in @('{', '[]', '{"schema_version":1.0,"version":"0.1.0","driver_revision":2,"driver_date":"2026-07-27"}', '{"schema_version":1,"version":"0.1.0","version":"0.2.0","driver_revision":2,"driver_date":"2026-07-27"}', '{"SCHEMA_VERSION":1,"version":"0.1.0","driver_revision":2,"driver_date":"2026-07-27"}', '{"schema_version":1,"version":"0.1.0","driver_revision":2,"driver_date":"2026-02-30"}', '{"schema_version":1,"version":"0.1.0","driver_revision":2.5,"driver_date":"2026-07-27"}', '{"schema_version":1,"version":"0.1.0","driver_revision":65535,"driver_date":"2026-07-27"}', '{"schema_version":1,"version":"0.0.0","driver_revision":0,"driver_date":"2026-07-27"}')) {
    [IO.File]::WriteAllText($jsonPath, $invalidJson)
    Assert-Rejected { Test-VersionConsistency $fixture } 'Malformed/invalid canonical JSON'
}
[IO.File]::WriteAllText($jsonPath, $originalJson)

# Exercise the complete update transaction on the fixture, never the real tree.
# Choose a new core above the checked-out version to keep tests reusable after bumps.
$nextMinor = $baseline.Semantic.Minor + 1
if ($nextMinor -gt 65534) { throw 'Version test needs a fresh next-minor fixture core.' }
$testCore = '{0}.{1}.0' -f $baseline.Semantic.Major, $nextMinor
$date = $baseline.DriverDate
$first = Update-ProjectVersion $fixture ($testCore + '-rc.1') 0 $date
Assert-Equal $first.Version ($testCore + '-rc.1') 'Setter advances all SemVer sources'
Assert-Equal $first.DriverVersion ($testCore + '.0') 'Setter maps Windows version'
$before = Get-FixtureDigest
Assert-Rejected { Update-ProjectVersion $fixture ($testCore + '-rc.2') 0 $date } 'Same-core prerelease must advance Windows revision'
Assert-Equal (Get-FixtureDigest) $before 'Rejected Windows version preserves every file'
$second = Update-ProjectVersion $fixture ($testCore + '-rc.2') 1 $date
Assert-Equal $second.DriverVersion ($testCore + '.1') 'Same-core prerelease revision advances'
$stable = Update-ProjectVersion $fixture $testCore 2 $date
Assert-Equal $stable.Version $testCore 'Prerelease promotes to stable'
Assert-Equal $stable.DriverVersion ($testCore + '.2') 'Stable promotion advances Windows version'
$before = Get-FixtureDigest
Assert-Rejected { Update-ProjectVersion $fixture ($testCore + '+build.1') 3 $date } 'Build metadata alone cannot create release'
Assert-Rejected { Update-ProjectVersion $fixture ($testCore + '-rc.3') 3 $date } 'SemVer downgrade is rejected'
Assert-Rejected { Update-ProjectVersion $fixture ('{0}.{1}.1' -f $baseline.Semantic.Major, $nextMinor) 0 '2000-01-01' } 'Driver date cannot move backwards'
Assert-Equal (Get-FixtureDigest) $before 'Rejected releases preserve every file'
Assert-Equal @(Get-ChildItem -LiteralPath $fixture -Filter '*.tmp' -File -Recurse).Count 0 'Version transactions clean temporary files'
$null = Test-VersionConsistency $repository
Write-Host "Version tooling checks passed ($script:Assertions assertions)."
